use std::{panic, sync::Arc};

use ankurah::core::context::Context;
use ankurah::{policy::DEFAULT_CONTEXT as c, Node, PermissiveAgent};
pub use ankurah_storage_indexeddb_wasm::IndexedDBStorageEngine;
pub use ankurah_websocket_client_wasm::WebsocketClient;
use lazy_static::lazy_static;
use once_cell::sync::OnceCell;
use send_wrapper::SendWrapper;
use tracing::error;
use wasm_bindgen::{prelude::wasm_bindgen, JsValue};
use web_sys::window;

pub use ankurah_template_model::*;

// Re-export the new useObserve hook from ankurah-signals
pub use ankurah_signals::{react::*, JsValueMut, JsValueRead};

lazy_static! {
    static ref NODE: OnceCell<Node<IndexedDBStorageEngine, PermissiveAgent>> = OnceCell::new();
    static ref CLIENT: OnceCell<SendWrapper<WebsocketClient>> = OnceCell::new();
    static ref NOTIFY: tokio::sync::Notify = tokio::sync::Notify::new();
}

#[wasm_bindgen(start)]
pub async fn start() -> Result<(), JsValue> {
    // Configure tracing_wasm to filter out DEBUG logs
    tracing_wasm::set_as_global_default_with_config(
        tracing_wasm::WASMLayerConfigBuilder::new()
            .set_max_level(tracing::Level::INFO) // Only show INFO, WARN, ERROR
            .build(),
    );
    panic::set_hook(Box::new(console_error_panic_hook::hook));

    let storage_engine = IndexedDBStorageEngine::open("ankurah_template_app")
        .await
        .map_err(|e| JsValue::from_str(&e.to_string()))?;
    let node = Node::new(Arc::new(storage_engine), PermissiveAgent::new());

    // Build WebSocket URL based on current window location
    let window = window().ok_or_else(|| JsValue::from_str("No window available"))?;
    let location = window.location();
    let hostname = location
        .hostname()
        .map_err(|e| JsValue::from_str(&format!("Failed to get hostname: {:?}", e)))?;
    let ws_url = format!("ws://{}:9898", hostname);

    let connector = WebsocketClient::new(node.clone(), &ws_url)
        .map_err(|e| JsValue::from_str(&e.to_string()))?;
    node.system.wait_system_ready().await;
    if let Err(_) = NODE.set(node) {
        error!("Failed to set node");
    }
    if let Err(_) = CLIENT.set(SendWrapper::new(connector)) {
        error!("Failed to set connector");
    }
    NOTIFY.notify_waiters();

    Ok(())
}

pub fn get_node() -> Node<IndexedDBStorageEngine, PermissiveAgent> {
    NODE.get().expect("Node not initialized").clone()
}

#[wasm_bindgen]
pub fn ctx() -> Result<Context, JsValue> {
    get_node()
        .context(c)
        .map_err(|e| JsValue::from_str(&e.to_string()))
}

#[wasm_bindgen]
pub fn ws_client() -> WebsocketClient {
    (**CLIENT.get().expect("Client not initialized")).clone()
}

#[wasm_bindgen]
pub async fn ready() -> Result<(), JsValue> {
    match CLIENT.get() {
        Some(client) => client.ready().await,
        None => {
            NOTIFY.notified().await;
            CLIENT.get().expect("Client not initialized").ready().await
        }
    }
    .map_err(|_| JsValue::from_str("Failed to connect to server"))
}

// Just export the models and basic primitives
// All business logic should be in the React app

// Generate MessageScrollManager in bindings crate (keeps model platform-agnostic)
use ankurah_template_model::{MessageView, MessageLiveQuery};
ankurah_virtual_scroll::generate_scroll_manager!(
    Message,
    MessageView,
    MessageLiveQuery,
    timestamp_field = "timestamp"
);
