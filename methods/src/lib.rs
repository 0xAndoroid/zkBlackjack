//! Generated crate containing the image ID and ELF binary of the build guest.
include!(concat!(env!("OUT_DIR"), "/methods.rs"));

#[cfg(test)]
mod tests {
    use alloy_primitives::U256;
    use alloy_sol_types::{sol, SolValue};
    use k256::ecdsa::signature::SignerMut;
    use k256::ecdsa::{Signature, SigningKey, VerifyingKey};
    use risc0_zkvm::{default_executor, ExecutorEnv};

    sol!(
        struct Input {
            bytes16 dealer_seed;
            GameInput[] games;
        }
    );

    sol!(
        struct GameInput {
            bytes16 player_seed;
            bytes pubkey;
            uint8 initial_hands;
            uint256[] bets;
            DeAction[] actions;
            bytes32[2][] signatures;
        }
    );

    sol!(
        struct DeAction {
            uint8 nonce;
            uint8 hand_id;
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

    #[test]
    fn test_correct_game() {
        let sk = SigningKey::random(&mut rand::thread_rng());
        let vk = VerifyingKey::from(&sk).to_encoded_point(false).to_bytes();
        let action = DeAction {
            nonce: 0,
            hand_id: 0,
            inner: 2,
            my_cards: vec![2, 9],
            dealer_cards: vec![10, 4],
        };
        let signature = sign_action(&action, sk);
        let game = GameInput {
            player_seed: [1u8; 16].into(),
            pubkey: vk.clone().into(),
            initial_hands: 1,
            bets: vec![U256::from(100)],
            actions: vec![action],
            signatures: vec![[
                signature[0..32].try_into().unwrap(),
                signature[32..64].try_into().unwrap(),
            ]],
        };
        let inputs = Input {
            dealer_seed: [0u8; 16].into(),
            games: vec![game],
        };

        let env = ExecutorEnv::builder().write_slice(&inputs.abi_encode()).build().unwrap();

        let session_info = default_executor().execute(env, super::BLACKJACK_ELF).unwrap();

        let x = Output::abi_decode(&session_info.journal.bytes, true).unwrap();
        assert_eq!(x.payouts[0], U256::from(0));
        assert_eq!(x.terminated[0], true);
    }

    fn sign_action(action: &DeAction, mut sk: SigningKey) -> Vec<u8> {
        let sig: Signature = sk.sign(&action.abi_encode());
        sig.to_bytes().to_vec()
    }
}
