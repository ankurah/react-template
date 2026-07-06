# ankurah-template Chat

A simple real-time chat application built with Ankurah, demonstrating distributed reactive updates across React frontend and Rust backend.

## Features

- Real-time message synchronization
- Persistent storage (Sled or Postgres on the server, IndexedDB in browser)
- Automatic user creation with localStorage persistence
- WebSocket-based peer communication
- Reactive UI updates

## Architecture

- **model/** - Shared data models (User, Room, Message)
- **server/** - Rust server (Sled or Postgres storage) and WebSocket connector
- **wasm-bindings/** - WASM bindings exposing Ankurah to JavaScript
- **react-app/** - React frontend application

## Storage engine

The durable server node stores data in **Sled** by default. Generate the project
with `--define storage=postgres` (or choose Postgres at the prompt) to back it
with **Postgres** instead; the bundled `./dev.sh` then brings up a Postgres
container automatically on a randomized port. Both paths are wired through the
`sled` / `postgres` features in `server/Cargo.toml`.

## Quick Start

### 1. Build and run the server

```bash
cargo run -p ankurah-template-server
```

The server will:

- Initialize Sled storage at `~/.ankurah-template/`
- Create a "General" chat room
- Listen for WebSocket connections on `127.0.0.1:9898`

### 2. Build the WASM bindings

```bash
cd wasm-bindings
wasm-pack build --target web --dev
cd ..
```

### 3. Run the React app

```bash
cd react-app
bun install
bun run dev
```

The app will be available at `http://localhost:5173`

## Models

### User

- `display_name`: String (YrsString) - User's display name

### Room

- `name`: String (YrsString) - Room name

### Message

- `user`: String (LWW) - User ID who sent the message
- `room`: String (LWW) - Room ID where message was sent
- `text`: String (YrsString) - Message content
- `timestamp`: i64 (LWW) - Unix timestamp in milliseconds

## Development

### Building for production

```bash
# Server
cargo build --release -p ankurah-template-server

# WASM
cd wasm-bindings && wasm-pack build --target web --release

# React app
cd react-app && bun run build
```

## License

MIT or Apache-2.0
