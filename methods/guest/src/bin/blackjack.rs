use std::io::Read;

use alloy_primitives::{FixedBytes, U256};
use alloy_sol_types::{sol, SolValue};
use risc0_zkvm::guest::env;

use rand::{Rng, SeedableRng};
use rand_chacha::ChaCha8Rng;

use sha2::Digest;

use k256::{
    ecdsa::{signature::Verifier, Signature, VerifyingKey},
    EncodedPoint,
};

sol!(
    struct Input {
        bytes16 dealerSeed;
        GameInput[] games;
    }
);

sol!(
    struct GameInput {
        bytes16 playerSeed;
        bytes pubkey;
        uint8 initialHands;
        uint256[] bets;
        DeAction[] actions;
        bytes32[2][] signatures;
    }
);

sol!(
    struct DeAction {
        uint8 nonce;
        uint8 handId;
        uint8 inner;
        uint8[] my_cards;
        uint8[] dealer_cards;
    }
);

sol!(
    struct Output {
        bytes32 dealer_commitment;
        bytes32[] player_commitments;
        bytes[] player_pubkeys;
        uint256[] payouts;
        uint8[][] double_hands;
        uint8[][] split_hands;
        bytes32[] action_hash;
        bool[] terminated;
    }
);

fn main() {
    let mut input_bytes = Vec::<u8>::new();
    env::stdin().read_to_end(&mut input_bytes).unwrap();

    let inputs = <Input>::abi_decode(&input_bytes, true).expect("decode input");
    let mut hasher = sha2::Sha256::new();
    hasher.update(inputs.dealerSeed);
    let dealer_commitment: [u8; 32] = hasher.finalize().into();

    let mut player_commitments = Vec::<FixedBytes<32>>::new();
    let mut player_pubkeys = Vec::<alloy_primitives::Bytes>::new();
    let mut payouts = Vec::<U256>::new();
    let mut double_hands = Vec::<Vec<u8>>::new();
    let mut split_hands = Vec::<Vec<u8>>::new();
    let mut action_hash = Vec::<[u8; 32]>::new();
    let mut terminated = Vec::<bool>::new();

    for game in inputs.games {
        let mut hasher = sha2::Sha256::new();
        hasher.update(game.playerSeed);
        player_commitments
            .push(hasher.finalize().as_slice().try_into().expect("player commitment"));
        player_pubkeys.push(game.pubkey.clone());

        let pubkey = VerifyingKey::from_encoded_point(
            &EncodedPoint::from_bytes(&game.pubkey).expect("pubkey"),
        )
        .expect("verifying key");

        assert_eq!(game.actions.len(), game.signatures.len());
        let mut terminate = false;
        for ((action, signature), nonce) in
            game.actions.iter().zip(game.signatures).zip(0..game.actions.len() as u8)
        {
            assert_eq!(action.nonce, nonce);
            let action_bytes = action.abi_encode();
            let signature = Signature::from_slice(
                &signature[0].into_iter().chain(signature[1]).collect::<Vec<u8>>(),
            );
            if signature.is_err() {
                double_hands.push(Vec::new());
                split_hands.push(Vec::new());
                payouts.push(U256::ZERO);
                action_hash.push(sha2::Sha256::digest(game.actions.abi_encode().as_slice()).into());
                terminated.push(false);
                terminate = true;
                break;
            }
            let verif = pubkey.verify(&action_bytes, &signature.unwrap());
            if verif.is_err() {
                double_hands.push(Vec::new());
                split_hands.push(Vec::new());
                payouts.push(U256::ZERO);
                action_hash.push(sha2::Sha256::digest(game.actions.abi_encode().as_slice()).into());
                terminated.push(false);
                terminate = true;
                break;
            }
        }
        if terminate {
            continue;
        }

        let actions = game.actions.iter().map(|action| action.into()).collect::<Vec<Action>>();

        let game_seed: [u8; 32] = inputs
            .dealerSeed
            .into_iter()
            .chain(game.playerSeed)
            .collect::<Vec<u8>>()
            .try_into()
            .expect("game seed len");

        let (results, doubled_hands_game, split_hands_game) =
            match run_blackjack(game_seed, game.initialHands as usize, actions) {
                Ok(v) => v,
                Err(_) => {
                    double_hands.push(Vec::new());
                    split_hands.push(Vec::new());
                    payouts.push(U256::ZERO);
                    action_hash.push(sha2::Sha256::digest(game.actions.abi_encode().as_slice()).into());
                    terminated.push(false);
                    continue;
                }
            };

        double_hands.push(doubled_hands_game);
        split_hands.push(split_hands_game);
        let payout = eval_payout(&game.bets, &results);
        payouts.push(payout);
        action_hash.push([0u8; 32]);
        terminated.push(true);
    }
    let action_hash = action_hash.into_iter().map(|x| x.into()).collect::<Vec<_>>();

    let output = Output {
        dealer_commitment: dealer_commitment.into(),
        player_commitments,
        player_pubkeys,
        payouts,
        double_hands,
        split_hands,
        action_hash,
        terminated,
    };
    env::commit_slice(output.abi_encode().as_slice());
}

impl From<&DeAction> for Action {
    fn from(v: &DeAction) -> Action {
        Action {
            hand_id: v.handId,
            inner: v.inner.into(),
            my_cards: v.my_cards.clone(),
            dealer_cards: v.dealer_cards.clone(),
        }
    }
}

pub struct Action {
    pub hand_id: u8,
    pub inner: ActionType,
    pub my_cards: Vec<u8>,
    pub dealer_cards: Vec<u8>,
}

#[derive(PartialEq, Debug)]
pub enum ActionType {
    Hit,
    Stand,
    Double,
    Split,
}

impl From<u8> for ActionType {
    fn from(value: u8) -> Self {
        match value {
            0 => ActionType::Hit,
            1 => ActionType::Stand,
            2 => ActionType::Double,
            3 => ActionType::Split,
            _ => panic!("Invalid action type"),
        }
    }
}

impl From<ActionType> for u8 {
    fn from(value: ActionType) -> Self {
        match value {
            ActionType::Hit => 0,
            ActionType::Stand => 1,
            ActionType::Double => 2,
            ActionType::Split => 3,
        }
    }
}

pub enum HandResult {
    Bj,
    Win,
    Push,
    Lose,
    DoubleWin,
    DoubleLose,
    DoublePush,
}

pub enum Error {
    InvalidAction,
    UnexpectedHand,
}

fn eval_payout(bets: &[U256], results: &[HandResult]) -> U256 {
    bets.iter()
        .zip(results)
        .map(|(bet, result)| match result {
            HandResult::Bj => {
                bet.checked_mul(U256::from(5)).unwrap().checked_div(U256::from(2)).unwrap()
            }
            HandResult::Win => bet.checked_mul(U256::from(2)).unwrap(),
            HandResult::Push => *bet,
            HandResult::Lose => U256::ZERO,
            HandResult::DoubleWin => bet.checked_mul(U256::from(4)).unwrap(),
            HandResult::DoubleLose => U256::ZERO,
            HandResult::DoublePush => bet.checked_mul(U256::from(2)).unwrap(),
        })
        .fold(U256::ZERO, |acc, x| acc.checked_add(x).unwrap())
}

fn run_blackjack(
    seed: [u8; 32],
    initial_hands: usize,
    actions: Vec<Action>,
) -> Result<(Vec<HandResult>, Vec<u8>, Vec<u8>), ()> {
    let mut rng = ChaCha8Rng::from_seed(seed);
    let mut dealer = [get_card(&mut rng), get_card(&mut rng)].to_vec();
    let mut player = (0..initial_hands)
        .map(|_| [get_card(&mut rng), get_card(&mut rng)].to_vec())
        .collect::<Vec<_>>();
    let mut player_active = std::iter::repeat(true).take(initial_hands).collect::<Vec<_>>();
    let mut doubled_hands: Vec<usize> = Vec::new();
    let mut split_hands: Vec<usize> = Vec::new();

    let mut expected_hand_action = 0u8;

    player.iter().enumerate().for_each(|(hand_id, hand)| {
        if is_blackjack(hand) {
            player_active[hand_id] = false;
        }
    });

    if is_blackjack(&dealer) {
        return Ok((
            player_active
                .iter()
                .map(|&hand| {
                    // just checked that false is blackjack
                    if hand {
                        HandResult::Lose
                    } else {
                        HandResult::Push
                    }
                })
                .collect(),
            Vec::new(),
            Vec::new(),
        ));
    }

    for Action {
        hand_id,
        inner,
        my_cards,
        dealer_cards,
    } in actions
    {
        // skip actions for hands that are not active
        while !player_active[expected_hand_action as usize] {
            expected_hand_action += 1;
        }
        if hand_id != expected_hand_action {
            return Err(());
        }
        // check if the cards match the state
        if player[hand_id as usize] != my_cards {
            return Err(());
        }
        if dealer != dealer_cards {
            return Err(());
        }
        let hand_id = hand_id as usize;
        match inner {
            ActionType::Hit => {
                if player[hand_id].iter().sum::<u8>() > 21 {
                    return Err(());
                }
                player[hand_id].push(get_card(&mut rng));
                if player[hand_id].iter().sum::<u8>() > 21 {
                    player_active[hand_id] = false;
                    expected_hand_action += 1;
                }
            }
            ActionType::Stand => {
                player_active[hand_id] = false;
                expected_hand_action += 1;
            }
            ActionType::Double => {
                if player[hand_id].len() != 2 {
                    return Err(());
                }
                player[hand_id].push(get_card(&mut rng));
                player_active[hand_id] = false;
                doubled_hands.push(hand_id);
                expected_hand_action += 1;
            }
            ActionType::Split => {
                if player[hand_id].len() != 2 {
                    return Err(());
                }
                // max of 5 hands allowed
                if player.len() == 4 {
                    return Err(());
                }
                // can only split if both cards are the same
                if player[hand_id][0] != player[hand_id][1] {
                    return Err(());
                }
                player.insert(hand_id + 1, [player[hand_id][1]].to_vec());
                player[hand_id].pop();
                player[hand_id].push(get_card(&mut rng));
                split_hands.push(hand_id);
            }
        }
    }

    if player_active.iter().any(|&active| active) {
        return Err(());
    }

    let dealer_sum = loop {
        let number_of_aces = dealer.iter().filter(|&&card| card == 1).count();
        let mut dealer_sum = dealer.iter().sum::<u8>();
        (0..number_of_aces).for_each(|_| {
            if dealer_sum <= 11 {
                dealer_sum += 10;
            }
        });
        // stand on soft 17
        if dealer_sum >= 17 {
            break dealer_sum;
        }
        dealer.push(get_card(&mut rng));
    };

    let result: Vec<HandResult> = player
        .iter()
        .enumerate()
        .map(|(hand_id, hand)| {
            let number_of_aces = hand.iter().filter(|&&card| card == 1).count();
            let mut hand_sum = hand.iter().sum::<u8>();
            (0..number_of_aces).for_each(|_| {
                if hand_sum <= 11 {
                    hand_sum += 10;
                }
            });
            let double = doubled_hands.contains(&hand_id);

            if is_blackjack(hand) {
                return HandResult::Bj;
            }
            if hand_sum > 21 {
                return if double { HandResult::DoubleLose } else { HandResult::Lose };
            }
            if dealer_sum > 21 {
                return if double { HandResult::DoubleWin } else { HandResult::Win };
            }
            if dealer_sum == hand_sum {
                return if double { HandResult::DoublePush } else { HandResult::Push };
            }
            if dealer_sum > hand_sum {
                return if double { HandResult::DoubleLose } else { HandResult::Lose };
            }
            if double {
                HandResult::DoubleWin
            } else {
                HandResult::Win
            }
        })
        .collect();

    let doubled_hands = doubled_hands.into_iter().map(|n| n as u8).collect();
    let split_hands = split_hands.into_iter().map(|n| n as u8).collect();
    Ok((result, doubled_hands, split_hands))
}

fn get_card(rng: &mut ChaCha8Rng) -> u8 {
    let card: u8 = rng.gen::<u8>() % 13 + 1;
    if card > 10 {
        10
    } else {
        card
    }
}

fn is_blackjack(hand: &[u8]) -> bool {
    hand.len() == 2 && hand.iter().any(|&card| card == 1) && hand.iter().any(|&card| card == 10)
}
