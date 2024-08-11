use std::sync::Arc;

use alloy_primitives::U256;
use app::eth;
use app::web::{self, web_task};
use clap::Parser;

/// Arguments of the publisher CLI.
#[derive(Parser, Debug)]
#[clap(author, version, about, long_about = None)]
struct Args {
    /// Ethereum chain ID
    #[clap(long)]
    chain_id: u64,

    /// Ethereum Node endpoint.
    #[clap(long, env)]
    eth_wallet_private_key: String,

    /// Ethereum Node endpoint.
    #[clap(long)]
    rpc_url: String,

    /// Application's contract address on Ethereum
    #[clap(long)]
    contract: String,

    /// The input to provide to the guest binary
    #[clap(short, long)]
    input: U256,
}

#[tokio::main]
async fn main() {
    env_logger::init();

    let eth = Arc::new(eth::Blockchain::new(
        11155111,
        "wss://sepolia.drpc.org",
        "",
        ""
    ).await.unwrap());

    tokio::task::spawn(web::web_task("0.0.0.0:3000", eth, [0; 16]));
}
