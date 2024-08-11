use alloy_primitives::{FixedBytes, U256};
use alloy_sol_types::SolValue;
use anyhow::{Context, Result};
use ethers::middleware::SignerMiddleware;
use ethers::providers::{Middleware, Provider, Ws};
use ethers::signers::{LocalWallet, Signer, Wallet};
use ethers::types::H256;
use k256::ecdsa::VerifyingKey;
use k256::EncodedPoint;

// should prob monitor the chain for new events, but no time to implement that
pub async fn eth_task() {
    todo!()
}

pub struct Blockchain {
    chain_id: u64,
    client: SignerMiddleware<Provider<Ws>, Wallet<k256::ecdsa::SigningKey>>,
    contract: ethers::types::Address,
}

impl Blockchain {
    pub async fn new(
        chain_id: u64,
        rpc_url: &str,
        private_key: &str,
        contract: &str,
    ) -> Result<Self> {
        let provider = Provider::<Ws>::connect(rpc_url).await?;
        let wallet: LocalWallet = private_key.parse::<LocalWallet>()?.with_chain_id(chain_id);
        let client = SignerMiddleware::new(provider.clone(), wallet.clone());
        let contract = contract.parse::<ethers::types::Address>()?;

        Ok(Self {
            chain_id,
            client,
            contract,
        })
    }

    // this is ugly af, but i don't care. it's 5am and i have 6.5 hours to finish this
    pub async fn get_start_tx(&self, tx_hash: &str) -> Result<StartData> {
        let tx = self
            .client
            .get_transaction_receipt(tx_hash.parse::<H256>()?)
            .await?
            .context("get_transaction")?;
        if tx.logs.len() != 1 {
            anyhow::bail!("invalid logs length");
        }
        let log = &tx.logs[0];
        if log.address != self.contract {
            anyhow::bail!("invalid contract address");
        }
        let log = log.data.clone();
        let calldata = match tx.other.get("input").context("input")? {
            serde_json::Value::String(data) => hex::decode(data)?,
            _ => anyhow::bail!("invalid input"),
        };
        let (_player, game_index, _dealer) =
            <(alloy_primitives::Address, U256, alloy_primitives::Address)>::abi_decode(&log, true)?;

        let (dealer, init_bets, player_commitment, player_pubkey) = <(
            alloy_primitives::Address,
            Vec<U256>,
            FixedBytes<32>,
            alloy_primitives::Bytes,
        )>::abi_decode(
            &calldata, true
        )?;

        if dealer.0.as_slice() != self.client.address().as_bytes() {
            anyhow::bail!("invalid dealer");
        }

        Ok(StartData {
            bets: init_bets,
            player_commitment: player_commitment.0.to_vec(),
            player_pubkey: VerifyingKey::from_encoded_point(&EncodedPoint::from_bytes(
                &player_pubkey.to_vec(),
            )?)?,
            game_index: game_index.as_limbs()[0],
        })
    }
}

pub struct StartData {
    pub bets: Vec<U256>,
    pub player_commitment: Vec<u8>,
    pub player_pubkey: VerifyingKey,
    pub game_index: u64,
}
