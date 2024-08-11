use crate::sm::{GameInput, Input};
use alloy_sol_types::SolValue;
use anyhow::Result;
use methods::BLACKJACK_ELF;
use risc0_ethereum_contracts::groth16;
use risc0_zkvm::{default_prover, ExecutorEnv, ProverOpts, VerifierContext};

pub fn prove_inner(
    game_inputs: Vec<GameInput>,
    dealer_seed: [u8; 16],
) -> Result<(Vec<u8>, Vec<u8>)> {
    let input = Input {
        games: game_inputs,
        dealerSeed: dealer_seed.into(),
    };
    let input = input.abi_encode();
    let env = ExecutorEnv::builder().write_slice(&input).build()?;
    let receipt = default_prover()
        .prove_with_ctx(env, &VerifierContext::default(), BLACKJACK_ELF, &ProverOpts::groth16())?
        .receipt;
    let seal = groth16::encode(receipt.inner.groth16()?.seal.clone())?;
    let journal = receipt.journal.bytes.clone();

    Ok((seal, journal))
}
