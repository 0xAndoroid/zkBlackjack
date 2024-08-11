//! State machine for blackjack game

use alloy_primitives::U256;
use alloy_sol_types::sol;
use alloy_sol_types::SolValue;
use k256::ecdsa::signature::Verifier;
use k256::ecdsa::VerifyingKey;
use rand::Rng;
use rand::SeedableRng;
use rand_chacha::ChaCha8Rng;

pub struct BlackjackStateMachine {
    pub dealer_seed: [u8; 16],
    player_seed: [u8; 16],
    pub dealer_hand: Vec<u8>,
    pub player_hands: Vec<Vec<u8>>,
    doubles: Vec<u8>,
    splits: Vec<u8>,

    initial_bets: Vec<U256>,
    bets: Vec<U256>,
    // zeroed out in the beginning
    winnings: Vec<U256>,
    pub hands_active: Vec<bool>,

    player_pubkey: VerifyingKey,

    rng: ChaCha8Rng,

    hand_id: usize,

    actions: Vec<DeAction>,
    signatures: Vec<[u8; 64]>,
}

impl BlackjackStateMachine {
    pub fn new(
        dealer_seed: [u8; 16],
        player_seed: [u8; 16],
        player_pubkey: VerifyingKey,
        bets: Vec<U256>,
    ) -> Self {
        let bets_len = bets.len();
        let mut s = Self {
            dealer_seed,
            player_seed,
            dealer_hand: Vec::new(),
            player_hands: std::iter::repeat(Vec::new()).take(bets_len).collect(),
            doubles: Vec::new(),
            splits: Vec::new(),

            initial_bets: bets.clone(),
            bets,
            winnings: std::iter::repeat(U256::ZERO).take(bets_len).collect(),
            hands_active: std::iter::repeat(true).take(bets_len).collect(),

            player_pubkey,
            rng: ChaCha8Rng::from_seed(
                dealer_seed
                    .into_iter()
                    .chain(player_seed)
                    .collect::<Vec<_>>()
                    .as_slice()
                    .try_into()
                    .unwrap(),
            ),
            hand_id: 0,
            actions: Vec::new(),
            signatures: Vec::new(),
        };

        s.dealer_hand.push(get_card(&mut s.rng));
        s.dealer_hand.push(get_card(&mut s.rng));
        s.player_hands.iter_mut().for_each(|hand| {
            hand.push(get_card(&mut s.rng));
            hand.push(get_card(&mut s.rng));
        });

        s.player_hands.iter().enumerate().for_each(|(id, hand)| {
            if is_blackjack(hand) {
                s.hands_active[id] = false;
            }
        });

        if is_blackjack(&s.dealer_hand) {
            s.hands_active.iter_mut().enumerate().for_each(|(id, active)| {
                if !*active {
                    s.winnings[id] = s.bets[id];
                }
                *active = false
            });
        }

        s
    }

    pub fn try_input(&mut self, action: DeAction, signature: &[u8]) -> Result<(), anyhow::Error> {
        let signature = k256::ecdsa::Signature::from_slice(&signature)?;
        let msg = action.abi_encode();
        self.player_pubkey.verify(&msg, &signature)?;

        self.try_action(Action::from(&action))?;

        self.actions.push(action);
        self.signatures.push(signature.to_bytes().as_slice().try_into().unwrap());
        Ok(())
    }

    fn try_action(
        &mut self,
        Action {
            hand_id,
            inner,
            my_cards,
            dealer_cards,
        }: Action,
    ) -> Result<(), anyhow::Error> {
        if self.terminated() {
            anyhow::bail!("Game is terminated");
        }
        while !self.hands_active[self.hand_id] {
            self.hand_id += 1;
        }
        if self.hand_id >= self.bets.len() {
            anyhow::bail!("Game is terminated");
        }
        if hand_id != self.hand_id as u8 {
            anyhow::bail!("Invalid hand_id");
        }
        if my_cards != self.player_hands[hand_id as usize] {
            anyhow::bail!("Invalid my_cards");
        }
        if dealer_cards != self.dealer_hand {
            anyhow::bail!("Invalid dealer_cards");
        }
        match inner {
            ActionType::Hit => {
                if self.sum(hand_id) > 21 {
                    anyhow::bail!("Cannot hit");
                }
                self.player_hands[hand_id as usize].push(get_card(&mut self.rng));
                if self.sum(hand_id) > 21 {
                    self.hands_active[hand_id as usize] = false;
                    self.hand_id += 1;
                }
            }
            ActionType::Stand => {
                self.hands_active[hand_id as usize] = false;
                self.hand_id += 1;
            }
            ActionType::Double => {
                if self.player_hands[hand_id as usize].len() != 2 {
                    anyhow::bail!("Cannot double");
                }
                self.player_hands[hand_id as usize].push(get_card(&mut self.rng));
                self.hands_active[hand_id as usize] = false;
                self.bets[hand_id as usize] =
                    self.bets[hand_id as usize].checked_mul(U256::from(2)).unwrap();
                self.doubles.push(hand_id);
                self.hand_id += 1;
            }
            ActionType::Split => {
                if self.player_hands[hand_id as usize].len() != 2 {
                    anyhow::bail!("Cannot split");
                }
                if self.player_hands.len() == 4 {
                    anyhow::bail!("Cannot split");
                }
                if self.player_hands[hand_id as usize][0] != self.player_hands[hand_id as usize][1]
                {
                    anyhow::bail!("Cannot split");
                }
                self.player_hands
                    .insert(hand_id as usize + 1, vec![self.player_hands[hand_id as usize][1]]);
                self.bets.insert(hand_id as usize + 1, self.bets[hand_id as usize]);
                self.player_hands[hand_id as usize].pop();
                self.player_hands[hand_id as usize].push(get_card(&mut self.rng));
                self.splits.push(hand_id);
            }
        }

        if self.terminated() {
            while self.sum_max_dealer() < 17 {
                self.dealer_hand.push(get_card(&mut self.rng));
            }
            let dealer_sum = self.sum_max_dealer();
            self.player_hands.clone().iter().enumerate().for_each(|(id, hand)| {
                let hand_sum = self.sum_max(id as u8);
                if is_blackjack(hand) {
                    self.winnings[id] = self.bets[id]
                        .checked_mul(U256::from(5))
                        .unwrap()
                        .checked_div(U256::from(2))
                        .unwrap();
                } else if hand_sum > 21 {
                    self.winnings[id] = U256::ZERO;
                } else if dealer_sum > 21 || hand_sum > dealer_sum {
                    self.winnings[id] = self.bets[id].checked_mul(U256::from(2)).unwrap();
                } else if hand_sum == dealer_sum {
                    self.winnings[id] = self.bets[id];
                } else {
                    self.winnings[id] = U256::ZERO;
                }
            });
        }

        Ok(())
    }

    fn sum(&self, hand_id: u8) -> u8 {
        self.player_hands[hand_id as usize].iter().sum()
    }

    fn sum_max(&self, hand_id: u8) -> u8 {
        let mut sum = self.sum(hand_id);
        if self.player_hands[hand_id as usize].iter().any(|&card| card == 1) && sum + 10 <= 21 {
            sum += 10;
        }
        sum
    }

    fn sum_max_dealer(&self) -> u8 {
        let mut sum = self.dealer_hand.iter().sum();
        if self.dealer_hand.iter().any(|&card| card == 1) && sum + 10 <= 21 {
            sum += 10;
        }
        sum
    }

    pub fn terminated(&self) -> bool {
        self.hands_active.iter().all(|&active| !active)
    }

    pub fn extract(self) -> Option<GameInput> {
        if self.terminated() {
            Some(GameInput {
                playerSeed: self.player_seed.into(),
                pubkey: self.player_pubkey.to_encoded_point(false).as_bytes().to_vec().into(),
                initialHands: self.initial_bets.len() as u8,
                bets: self.initial_bets,
                actions: self.actions,
                signatures: self
                    .signatures
                    .into_iter()
                    .map(|s| [s[0..32].try_into().unwrap(), s[32..].try_into().unwrap()])
                    .collect(),
            })
        } else {
            None
        }
    }
}

#[derive(serde::Deserialize)]
pub struct Action {
    pub hand_id: u8,
    pub inner: ActionType,
    pub my_cards: Vec<u8>,
    pub dealer_cards: Vec<u8>,
}

#[derive(PartialEq, Debug, serde::Deserialize)]
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
