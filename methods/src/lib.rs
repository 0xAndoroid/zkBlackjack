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
        }
    );

    #[test]
    fn test_correct_game() {
        let sk = SigningKey::random(&mut rand::thread_rng());
        let vk = VerifyingKey::from(&sk).to_encoded_point(false).to_bytes();
        let action = DeAction {
            nonce: 0,
            handId: 0,
            inner: 1,
        };
        let signature = sign_action(&action, sk);
        let game = GameInput {
            playerSeed: [1u8; 16].into(),
            pubkey: vk.into(),
            initialHands: 1,
            bets: vec![U256::from(100)],
            actions: vec![action],
            signatures: vec![[
                signature[0..32].try_into().unwrap(),
                signature[32..64].try_into().unwrap(),
            ]],
        };
        let inputs = Input {
            dealerSeed: [0u8; 16].into(),
            games: vec![game],
        };

        let env = ExecutorEnv::builder().write_slice(&inputs.abi_encode()).build().unwrap();

        let session_info = default_executor().execute(env, super::BLACKJACK_ELF).unwrap();

        let x = Output::abi_decode(&session_info.journal.bytes, true).unwrap();
        assert_eq!(x.payouts[0], U256::from(0));
    }

    fn sign_action(action: &DeAction, mut sk: SigningKey) -> Vec<u8> {
        let sig: Signature = sk.sign(&action.abi_encode());
        sig.to_bytes().to_vec()
    }
}
