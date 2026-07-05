use ankurah::{policy::DEFAULT_CONTEXT as c, Node, PermissiveAgent};
use ankurah_template_model::{Room, RoomView};
use ankurah_websocket_server::WebsocketServer;
use anyhow::Result;
use std::sync::Arc;
use tracing::{info, Level};

#[cfg(all(feature = "sled", not(feature = "postgres")))]
use ankurah_storage_sled::SledStorageEngine;
#[cfg(feature = "postgres")]
use ankurah_storage_postgres::Postgres;

// Storage engine selected at generate time (the crate's default feature).
// dev.sh reads that choice back to decide whether to run a Postgres container.
#[cfg(all(feature = "sled", not(feature = "postgres")))]
type Storage = SledStorageEngine;
#[cfg(feature = "postgres")]
type Storage = Postgres;

#[cfg(all(feature = "sled", not(feature = "postgres")))]
async fn make_storage() -> Result<Storage> {
    Ok(SledStorageEngine::with_homedir_folder(".ankurah-template")?)
}

#[cfg(feature = "postgres")]
async fn make_storage() -> Result<Storage> {
    // DATABASE_URL is provided by dev.sh (it points at the randomized-port
    // Postgres container). The fallback is only for running the server directly.
    let uri = std::env::var("DATABASE_URL")
        .unwrap_or_else(|_| "postgres://postgres:ankurah@localhost:5432/ankurah_template".to_string());
    Ok(Postgres::open(&uri).await?)
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt().with_max_level(Level::INFO).init(); // initialize tracing

    // Initialize storage engine (Sled or Postgres — see this crate's features)
    let storage = make_storage().await?;
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

async fn ensure_general_room(node: &Node<Storage, PermissiveAgent>) -> Result<()> {
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
