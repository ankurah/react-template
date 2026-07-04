use ankurah::{policy::DEFAULT_CONTEXT as c, Node, PermissiveAgent};
use ankurah_storage_sled::SledStorageEngine;
use ankurah_template_model::{Room, RoomView};
use ankurah_websocket_server::WebsocketServer;
use anyhow::Result;
use std::sync::Arc;
use tracing::{info, Level};

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt().with_max_level(Level::INFO).init(); // initialize tracing

    // Initialize storage engine
    let storage = SledStorageEngine::with_homedir_folder(".ankurah-template")?;
    let node = Node::new_durable(Arc::new(storage), PermissiveAgent::new());

    node.system.wait_loaded().await;
    if node.system.root().is_none() {
        node.system.create().await?;
    }

    // Ensure "General" room exists
    ensure_general_room(&node).await?;

    let mut server = WebsocketServer::new(node);
    // Port comes from dev.sh (randomized to avoid collisions); default for direct runs.
    let port = std::env::var("SERVER_PORT").unwrap_or_else(|_| "9898".to_string());
    server.run(&format!("0.0.0.0:{}", port)).await?;

    Ok(())
}

async fn ensure_general_room(node: &Node<SledStorageEngine, PermissiveAgent>) -> Result<()> {
    let context = node.context_async(c).await;

    // Query for a room named "General"
    let rooms = context.fetch::<RoomView>("name = 'General'").await?;

    if rooms.is_empty() {
        info!("Creating 'General' room");

        let trx = context.begin();
        trx.create(&Room {
            name: "General".to_string(),
        })
        .await?;
        trx.commit().await?;

        info!("'General' room created");
    } else {
        info!("'General' room already exists");
    }

    Ok(())
}
