#![allow(dead_code)]
#![allow(unused_variables)]

use std::collections::HashMap;
use std::sync::Arc;

use axum::extract::State;
use axum::http::StatusCode;
use axum::routing::post;
use axum::{Json, Router};
use tokio::sync::{Mutex, RwLock};

use crate::eth::Blockchain;
use crate::sm::BlackjackStateMachine;

#[derive(Clone)]
struct AppState {
    sm: Arc<RwLock<HashMap<u64, Mutex<BlackjackStateMachine>>>>,
    eth: Arc<Blockchain>,
    my_seed: [u8; 16],
}

pub async fn web_task(host: &str, eth: Arc<Blockchain>, my_seed: [u8; 16]) {
    let state_machines = Arc::new(RwLock::new(HashMap::<u64, Mutex<BlackjackStateMachine>>::new()));
    let state = AppState {
        sm: state_machines,
        eth,
        my_seed,
    };
    let app =
        Router::new().route("/start", post(start)).route("/action", post(action)).with_state(state);
    let listener = tokio::net::TcpListener::bind(&host).await.unwrap();
    axum::serve(listener, app).await.unwrap();
}

#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct StartRequest {
    tx_hash: String,
    player_seed: String,
}

#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
struct StartResponse {
    player_hands: Vec<Vec<u8>>,
    dealer_hand: Vec<u8>,
    hands_active: Vec<bool>,
    game_index: u64,
}

async fn start(
    State(state): State<AppState>,
    Json(payload): Json<StartRequest>,
) -> Result<(StatusCode, Json<StartResponse>), StatusCode> {
    let player_seed = hex::decode(&payload.player_seed)
        .map_err(|_| StatusCode::BAD_REQUEST)?
        .try_into()
        .map_err(|_| StatusCode::BAD_REQUEST)?;
    let start =
        state.eth.get_start_tx(&payload.tx_hash).await.map_err(|_| StatusCode::BAD_REQUEST)?;
    state.sm.write().await.insert(
        start.game_index,
        Mutex::new(BlackjackStateMachine::new(
            state.my_seed,
            player_seed,
            start.player_pubkey,
            start.bets,
        )),
    );

    let read_ref = state.sm.read().await;
    let sm = read_ref.get(&start.game_index).unwrap().lock().await;

    Ok((
        StatusCode::OK,
        Json(StartResponse {
            player_hands: sm.player_hands.clone(),
            dealer_hand: sm.dealer_hand.clone(),
            hands_active: sm.hands_active.clone(),
            game_index: start.game_index,
        }),
    ))
}

#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct ActionRequest {
    action: Vec<u8>,
    signature: Vec<u8>,
    tx_hash: Option<String>,
}

#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
struct ActionResponse {
    player_hands: Vec<Vec<u8>>,
    dealer_hand: Vec<u8>,
    hands_active: Vec<bool>,
    winnings: Option<f64>
}

async fn action(Json(payload): Json<ActionRequest>) -> (StatusCode, Json<ActionResponse>) {
    todo!()
}
