#!/usr/bin/env bash

# Development script for ankurah-template Chat.
#
# Background-first dev runner. Supervises three units under one process group
# and publishes status to ~/.dev-runner/ so a Sutra dashboard can visualize this
# environment (no daemon, no SDK — just files). See:
#   https://github.com/synestheticsystems/sutra/blob/main/docs/INTEGRATION.md
#
# Units:
#   server  cargo run --release -p ankurah-template-server   (randomized port)
#   wasm    cargo watch -> wasm-pack build --target web --dev (no port)
#   react   bun run dev                                       (randomized port; proxies /ws)
#
# Usage: ./dev.sh [--stop|--restart|--status|--logs|--build|--list|--stop-all|--help]

set -euo pipefail

# --- Colors ---------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m' # No Color

# --- Paths & fixed ports --------------------------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)"
REGISTRY_DIR="$HOME/.dev-runner"
mkdir -p "$REGISTRY_DIR"

PID_FILE="$SCRIPT_DIR/.dev-pid"
LOG_FILE="$SCRIPT_DIR/.dev-log"

WASM_PATH="$SCRIPT_DIR/wasm-bindings"
FRONTEND_PATH="$SCRIPT_DIR/react-app"

# Ports are randomized (server = even, react = even+1) to avoid collisions with
# other local services, and kept sticky across restarts in .dev-ports. They are
# propagated to the app: the server binds $SERVER_PORT, and Vite serves $REACT_PORT
# and proxies /ws to the backend. select_ports() (below) fills these in.
PORTS_FILE="$SCRIPT_DIR/.dev-ports"
PORT_RANGE_MIN=10000
PORT_RANGE_MAX=19998
MAX_PORT_ATTEMPTS=50
SERVER_PORT=""
REACT_PORT=""

# --- Registry key: sha256(SCRIPT_DIR), stable per checkout ----------------
# Derived from the path (not the project name) so every generated project — and
# every checkout of it — gets a stable, unique id regardless of its name.
sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256
    else
        echo "fatal: sha256sum or shasum is required" >&2
        return 1
    fi
}

REGISTRY_KEY="$(printf "%s" "$SCRIPT_DIR" | sha256 | cut -c1-16 | tr 'A-F' 'a-f')"
if [ ${#REGISTRY_KEY} -lt 8 ] || [[ "$REGISTRY_KEY" == *[!0-9a-f]* ]]; then
    echo "fatal: invalid dev-runner registry key: ${REGISTRY_KEY:-<empty>}" >&2
    exit 1
fi
REGISTRY_FILE="$REGISTRY_DIR/$REGISTRY_KEY"

# --- Registry + status helpers -------------------------------------------
register_instance() {
    # *_PORT keys map to unit names by lowercased prefix (SERVER_PORT -> server,
    # REACT_PORT -> react), giving those rows an open-in-browser affordance.
    cat > "$REGISTRY_FILE" << EOF
DIR=$SCRIPT_DIR
PID=$1
SERVER_PORT=$SERVER_PORT
REACT_PORT=$REACT_PORT
STARTED=$(date +%s)
EOF
}

clear_all_status() {
    # Defensive: refuse to glob-delete if the key is somehow empty/short, which
    # would otherwise wipe every other project's status files in ~/.dev-runner/.
    local key="${REGISTRY_KEY:-}"
    if [ -z "$key" ] || [ ${#key} -lt 8 ]; then
        echo "clear_all_status: refusing because REGISTRY_KEY is missing or too short" >&2
        return 1
    fi
    rm -f "$REGISTRY_DIR/$key".*.status
}

unregister_instance() {
    clear_all_status || true
    rm -f "$REGISTRY_FILE"
}

update_status() {
    # Atomic write+rename: the watcher never sees a truncated interim state.
    local name="$1" status="$2"
    local file="$REGISTRY_DIR/$REGISTRY_KEY.$name.status"
    local tmp="$file.tmp.$$"
    printf "%s\n" "$status" > "$tmp" && mv -f "$tmp" "$file"
}

# Export so subshells / watcher hooks can publish their own status.
export REGISTRY_DIR REGISTRY_KEY
export -f update_status clear_all_status

# --- Small utilities ------------------------------------------------------
get_file_value() {
    local file=$1 key=$2
    awk -F= -v key="$key" '$1 == key { print substr($0, length(key) + 2); exit }' "$file" 2>/dev/null || true
}

pid_is_alive() {
    kill -0 "$1" 2>/dev/null
}

# TCP connect probe (bash builtin) — the server is a WebSocket endpoint with no
# plain-HTTP health route, so "port accepts a connection" is the readiness test.
tcp_open() {
    (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null
}

require_command() {
    local cmd=$1 install_msg=$2
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo -e "${RED}Error: $cmd is not installed${NC}" >&2
        echo "$install_msg" >&2
        exit 1
    fi
}

# --- Port selection (randomized, sticky) ----------------------------------
# Availability check: prefer an actual bind test (node) to avoid a TOCTOU race;
# fall back to a TCP connect probe when node isn't around.
ports_available() {
    if command -v node >/dev/null 2>&1; then
        node -e "
            const net = require('net');
            const ports = [$1, $2];
            const servers = ports.map(() => net.createServer());
            const closeAll = () => servers.forEach(s => { try { s.close(); } catch (e) {} });
            let ok = 0;
            servers.forEach((s, i) => {
                s.once('error', () => { closeAll(); process.exit(1); });
                s.once('listening', () => { if (++ok === servers.length) { closeAll(); process.exit(0); } });
                s.listen(ports[i], '0.0.0.0');
            });
        " >/dev/null 2>&1
    else
        ! tcp_open "$1" && ! tcp_open "$2"
    fi
}

random_even_port() {
    local span=$(( (PORT_RANGE_MAX - PORT_RANGE_MIN) / 2 ))
    echo $(( PORT_RANGE_MIN + (RANDOM % span) * 2 ))
}

# Propagate to subprocesses: the server binds SERVER_PORT; Vite serves REACT_PORT
# (VITE_PORT) and proxies /ws to the backend (VITE_SERVER_PORT).
export_ports() {
    export SERVER_PORT REACT_PORT VITE_PORT="$REACT_PORT" VITE_SERVER_PORT="$SERVER_PORT"
}

select_ports() {
    # Reuse sticky ports from a previous run if they're still free.
    if [ -f "$PORTS_FILE" ]; then
        SERVER_PORT="$(get_file_value "$PORTS_FILE" SERVER_PORT)"
        REACT_PORT="$(get_file_value "$PORTS_FILE" REACT_PORT)"
        if [ -n "$SERVER_PORT" ] && [ -n "$REACT_PORT" ] && ports_available "$SERVER_PORT" "$REACT_PORT"; then
            export_ports; return 0
        fi
        SERVER_PORT=""; REACT_PORT=""
    fi
    # Otherwise pick a fresh free pair (server even, react = even + 1).
    local i base
    for i in $(seq 1 "$MAX_PORT_ATTEMPTS"); do
        base="$(random_even_port)"
        if ports_available "$base" "$((base + 1))"; then
            SERVER_PORT="$base"; REACT_PORT="$((base + 1))"; break
        fi
    done
    if [ -z "$SERVER_PORT" ] || [ -z "$REACT_PORT" ]; then
        echo -e "${RED}Error: could not find a free port pair in ${PORT_RANGE_MIN}-${PORT_RANGE_MAX}${NC}" >&2
        exit 1
    fi
    printf 'SERVER_PORT=%s\nREACT_PORT=%s\n' "$SERVER_PORT" "$REACT_PORT" > "$PORTS_FILE"
    export_ports
}

format_elapsed() {
    local seconds=$1
    if [ "$seconds" -lt 60 ]; then echo "${seconds}s ago"
    elif [ "$seconds" -lt 3600 ]; then echo "$((seconds / 60))m ago"
    elif [ "$seconds" -lt 86400 ]; then echo "$((seconds / 3600))h $((seconds % 3600 / 60))m ago"
    else echo "$((seconds / 86400))d ago"; fi
}

status_line() {
    local file="$REGISTRY_DIR/$REGISTRY_KEY.$1.status"
    [ -f "$file" ] && cat "$file" || echo "unknown"
}

check_running() {
    # Recover a PID file from the registry if it went missing (e.g. cleared /tmp).
    if [ ! -f "$PID_FILE" ]; then
        if [ -f "$REGISTRY_FILE" ]; then
            local recovered_pid
            recovered_pid="$(get_file_value "$REGISTRY_FILE" PID)"
            if [ -n "$recovered_pid" ] && pid_is_alive "$recovered_pid"; then
                echo "$recovered_pid" > "$PID_FILE"
            else
                return 1
            fi
        else
            return 1
        fi
    fi

    local pid
    pid="$(cat "$PID_FILE")"
    if ! pid_is_alive "$pid"; then
        rm -f "$PID_FILE"
        unregister_instance
        return 1
    fi

    # Guard against PID recycling: the supervisor must still be its own
    # process-group leader.
    local pgid
    pgid="$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
    if [ -n "$pgid" ] && [ "$pgid" != "$pid" ]; then
        rm -f "$PID_FILE"
        unregister_instance
        return 1
    fi
    return 0
}

kill_process_group() {
    # External stop: signal the whole process group, escalating to -9.
    local pid=$1
    [ -n "$pid" ] && pid_is_alive "$pid" || return 0
    kill -- -"$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
    pkill -P "$pid" 2>/dev/null || true
    local _
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        pid_is_alive "$pid" || break
        sleep 0.5
    done
    if pid_is_alive "$pid"; then
        kill -9 -- -"$pid" 2>/dev/null || kill -9 "$pid" 2>/dev/null || true
    fi
}

# --- Preflight ------------------------------------------------------------
# Ensure wasm-bindings/pkg and react-app/node_modules exist before Vite starts,
# and fail fast if the WASM toolchain is broken. (Same intent as the original
# foreground runner's initial build + install.)
do_preflight() {
    require_command cargo "Install Rust with rustup: https://rustup.rs/"
    require_command wasm-pack "Install: curl https://rustwasm.github.io/wasm-pack/installer/init.sh -sSf | sh"
    require_command bun "Install: curl -fsSL https://bun.sh/install | bash"

    echo -e "${BLUE}[preflight]${NC} Building WASM bindings (wasm-pack --dev)..."
    if ! (cd "$WASM_PATH" && wasm-pack build --target web --dev >/dev/null); then
        echo -e "${RED}✗ WASM build failed.${NC} Re-run to see errors:" >&2
        echo "    (cd $WASM_PATH && wasm-pack build --target web --dev)" >&2
        exit 1
    fi
    echo -e "${GREEN}✓${NC} WASM bindings built"

    echo -e "${BLUE}[preflight]${NC} Installing React dependencies (bun install)..."
    if ! (cd "$FRONTEND_PATH" && bun install >/dev/null); then
        echo -e "${RED}✗ bun install failed.${NC}" >&2
        exit 1
    fi
    echo -e "${GREEN}✓${NC} Dependencies installed"
}

# --- Supervisor -----------------------------------------------------------
do_start() {
    # `set -m` makes the backgrounded supervisor its own process-group leader,
    # so its PID (captured below) is a PGID the parent can signal as a group.
    set -m
    (
        # Rejoin job control OFF inside the supervisor so our unit subshells
        # share THIS process group; then a single `kill -- -<pgid>` reaps the
        # whole tree (children and grandchildren).
        set +m

        CHILD_PIDS=""
        track_child() { CHILD_PIDS="$CHILD_PIDS $1"; }

        stop_children() {
            local pid
            for pid in $CHILD_PIDS; do
                kill "$pid" 2>/dev/null || true
                pkill -P "$pid" 2>/dev/null || true
            done
            sleep 0.5
            for pid in $CHILD_PIDS; do
                kill -9 "$pid" 2>/dev/null || true
                pkill -9 -P "$pid" 2>/dev/null || true
            done
        }

        cleanup() {
            trap - INT TERM HUP EXIT
            # Read our own PGID from the PID file (bash 3.2 has no $BASHPID).
            local pgid=""
            pgid="$(cat "$PID_FILE" 2>/dev/null || true)"
            rm -f "$PID_FILE" "$REGISTRY_FILE"
            clear_all_status || true
            stop_children
            # Reap anything still in our process group (incl. grandchildren).
            # NOTE: we deliberately do NOT `pkill -f "ankurah-template-server"`
            # here — a name/cmdline match is a footgun (it also kills editors,
            # greps, or log tails that merely mention the name). Process-group
            # reaping above is both scoped and complete.
            if [ -n "$pgid" ]; then kill -- -"$pgid" 2>/dev/null || true; fi
        }
        trap cleanup INT TERM HUP EXIT

        local sf="$REGISTRY_DIR/$REGISTRY_KEY"

        # -- server: build (building: cargo) then run (running -> ready) -------
        echo "[server] Building and starting on port $SERVER_PORT..."
        (
            cd "$SCRIPT_DIR"
            f="$sf.server.status"
            printf "%s\n" "building: cargo" > "$f.tmp" && mv -f "$f.tmp" "$f"
            if cargo build --release -p ankurah-template-server; then
                printf "%s\n" "running" > "$f.tmp" && mv -f "$f.tmp" "$f"
                # exec so the tracked PID is the server (no lingering cargo layer);
                # fall back to `cargo run` if the target dir is relocated.
                bin="$SCRIPT_DIR/target/release/ankurah-template-server"
                if [ -x "$bin" ]; then
                    exec "$bin"
                else
                    exec cargo run --release -p ankurah-template-server
                fi
            else
                printf "%s\n" "failed: build error" > "$f.tmp" && mv -f "$f.tmp" "$f"
            fi
        ) &
        track_child "$!"

        # -- wasm: cargo-watch rebuilds on change (building: wasm-pack -> ready)-
        # pkg was already built by the preflight, so `--postpone` skips the
        # redundant startup rebuild — which otherwise races Vite's first resolve
        # of the pkg import and spams "Failed to resolve import". The watcher
        # still rebuilds on subsequent source changes.
        echo "[wasm] Watching for changes (initial build done in preflight)..."
        update_status wasm "ready"
        (
            cd "$WASM_PATH"
            export STATUS_PREFIX="$sf"
            exec cargo watch --postpone -i pkg \
                -s 'f="$STATUS_PREFIX.wasm.status"; printf "%s\n" "building: wasm-pack" > "$f.tmp" && mv -f "$f.tmp" "$f"; if wasm-pack build --target web --dev; then printf "%s\n" "ready" > "$f.tmp" && mv -f "$f.tmp" "$f"; else printf "%s\n" "failed: wasm-pack" > "$f.tmp" && mv -f "$f.tmp" "$f"; fi'
        ) &
        track_child "$!"

        # -- react: Vite dev server (starting -> ready) ------------------------
        echo "[react] Starting dev server on port $REACT_PORT..."
        update_status react "starting"
        (
            cd "$FRONTEND_PATH"
            exec bun run dev
        ) &
        track_child "$!"

        # -- readiness sidecar: flip server/react to "ready" once reachable ----
        (
            server_ready=false
            react_ready=false
            i=0
            # Generous budget: the first server build is a cold release compile.
            while [ "$i" -lt 900 ]; do
                if [ "$server_ready" = false ] && tcp_open "$SERVER_PORT"; then
                    update_status server "ready"; server_ready=true
                fi
                if [ "$react_ready" = false ] && curl -sf "http://127.0.0.1:$REACT_PORT/" >/dev/null 2>&1; then
                    update_status react "ready"; react_ready=true
                fi
                [ "$server_ready" = true ] && [ "$react_ready" = true ] && break
                sleep 1
                i=$((i + 1))
            done
            [ "$server_ready" = false ] && update_status server "failed: readiness timeout"
            [ "$react_ready" = false ] && update_status react "failed: readiness timeout"
            true
        ) &
        track_child "$!"

        wait
    ) > "$LOG_FILE" 2>&1 &

    local bg_pid=$!
    set +m
    echo "$bg_pid" > "$PID_FILE"
    register_instance "$bg_pid"

    local actual_pgid
    actual_pgid="$(ps -o pgid= -p "$bg_pid" 2>/dev/null | tr -d ' ' || true)"
    if [ -n "$actual_pgid" ] && [ "$actual_pgid" != "$bg_pid" ]; then
        echo -e "${YELLOW}Warning: supervisor PID $bg_pid is not a process-group leader; child cleanup may be incomplete.${NC}" >&2
    fi

    sleep 0.5
    if ! pid_is_alive "$bg_pid"; then
        echo -e "${RED}Failed to start. Check logs:${NC} tail -50 $LOG_FILE" >&2
        kill_process_group "$bg_pid"
        rm -f "$PID_FILE"
        unregister_instance
        exit 1
    fi
}

# --- Presentation ---------------------------------------------------------
show_status() {
    local started now elapsed pid
    SERVER_PORT="$(get_file_value "$REGISTRY_FILE" SERVER_PORT)"
    REACT_PORT="$(get_file_value "$REGISTRY_FILE" REACT_PORT)"
    started="$(get_file_value "$REGISTRY_FILE" STARTED)"
    started="${started:-$(date +%s)}"
    now="$(date +%s)"
    elapsed=$((now - started))
    pid="$(cat "$PID_FILE" 2>/dev/null || echo unknown)"

    echo ""
    echo -e "${GREEN}ankurah-template dev environment running${NC}"
    echo ""
    echo -e "  ${DIM}Server:${NC}    ${CYAN}http://127.0.0.1:$SERVER_PORT${NC} ($(status_line server))"
    echo -e "  ${DIM}React:${NC}     ${CYAN}http://localhost:$REACT_PORT${NC} ($(status_line react))"
    echo -e "  ${DIM}WASM:${NC}      $(status_line wasm)"
    echo -e "  ${DIM}PID:${NC}       $pid"
    echo -e "  ${DIM}Started:${NC}   $(format_elapsed "$elapsed")"
    echo -e "  ${DIM}Log:${NC}       $LOG_FILE"
    echo ""
    echo -e "  ${DIM}--logs${NC}    Watch output      ${DIM}--stop${NC}    Stop services"
    echo ""
}

# --- Commands -------------------------------------------------------------
cmd_start() {
    if check_running; then
        show_status
        exit 0
    fi
    # Belt-and-suspenders: a prior crash may have left stale status rows.
    clear_all_status || true

    echo ""
    echo -e "${BOLD}Starting ankurah-template dev environment${NC}"
    echo ""
    select_ports
    echo -e "  ${DIM}Ports:${NC} server=$SERVER_PORT  react=$REACT_PORT  ${DIM}(randomized; sticky in .dev-ports)${NC}"
    echo ""

    do_preflight
    echo -e "${BLUE}[start]${NC} Launching supervisor (server + wasm watcher + react)..."
    do_start

    echo ""
    echo -e "${GREEN}✓ Dev environment started${NC}"
    echo -e "  ${DIM}Server:${NC} http://127.0.0.1:$SERVER_PORT   ${DIM}React:${NC} http://localhost:$REACT_PORT"
    echo -e "  Watch output with ${CYAN}./dev.sh --logs${NC}, stop with ${CYAN}./dev.sh --stop${NC}"
    echo ""
}

cmd_stop() {
    if ! check_running; then
        clear_all_status || true
        rm -f "$REGISTRY_FILE" "$PID_FILE"
        echo -e "${YELLOW}No running instance for this project${NC}"
        exit 0
    fi
    local pid
    pid="$(cat "$PID_FILE")"
    echo -e "Stopping ankurah-template dev environment (PID $pid)..."
    kill_process_group "$pid"
    rm -f "$PID_FILE"
    unregister_instance
    echo -e "${GREEN}✓ Stopped${NC}"
}

cmd_restart() {
    if check_running; then cmd_stop; fi
    echo ""
    cmd_start
}

cmd_logs() {
    if ! check_running; then
        echo -e "${RED}No running instance for this project${NC}" >&2
        exit 1
    fi
    [ -f "$LOG_FILE" ] || { echo -e "${RED}Log file not found: $LOG_FILE${NC}" >&2; exit 1; }
    echo -e "${DIM}Attaching to logs (Ctrl+C to detach)...${NC}"
    echo ""
    tail -f "$LOG_FILE"
}

cmd_build() {
    do_preflight
    echo -e "${GREEN}✓ Build complete${NC}"
}

cmd_list() {
    echo ""
    echo -e "${BOLD}Dev-runner instances${NC}"
    echo ""
    local found=0 regfile dir pid started now elapsed key
    for regfile in "$REGISTRY_DIR"/*; do
        [ -f "$regfile" ] || continue
        case "$regfile" in *.status) continue ;; esac
        dir="$(get_file_value "$regfile" DIR)"
        pid="$(get_file_value "$regfile" PID)"
        if [ -n "$pid" ] && pid_is_alive "$pid"; then
            started="$(get_file_value "$regfile" STARTED)"; now="$(date +%s)"
            elapsed=$((now - ${started:-$now}))
            echo -e "  ${CYAN}$dir${NC}"
            echo -e "    PID $pid, started $(format_elapsed "$elapsed")"
            found=1
        else
            # Reap a dead instance's leftovers.
            key="$(basename "$regfile")"
            rm -f "$REGISTRY_DIR/$key".*.status "$regfile"
        fi
    done
    [ "$found" -eq 0 ] && echo -e "  ${DIM}No running instances${NC}"
    echo ""
}

cmd_stop_all() {
    echo -e "Stopping all dev-runner instances..."
    local regfile pid stopped=0
    for regfile in "$REGISTRY_DIR"/*; do
        [ -f "$regfile" ] || continue
        case "$regfile" in *.status) continue ;; esac
        pid="$(get_file_value "$regfile" PID)"
        if [ -n "$pid" ] && pid_is_alive "$pid"; then
            kill_process_group "$pid"; stopped=$((stopped + 1))
        fi
        rm -f "$regfile" "${regfile}".*.status
    done
    echo -e "${GREEN}Stopped $stopped instance(s)${NC}"
}

cmd_help() {
    echo ""
    echo -e "${BOLD}Usage:${NC} ./dev.sh [command]"
    echo ""
    echo -e "  ${CYAN}(none)${NC}       Start services in the background, or show status if running"
    echo -e "  ${CYAN}--status${NC}     Show this project's running status"
    echo -e "  ${CYAN}--logs${NC}       Attach to combined logs (Ctrl+C to detach)"
    echo -e "  ${CYAN}--stop${NC}       Stop this project's dev processes"
    echo -e "  ${CYAN}--restart${NC}    Stop and start again"
    echo -e "  ${CYAN}--build${NC}      Run the wasm-pack + bun install preflight only"
    echo -e "  ${CYAN}--list${NC}       List all dev-runner instances"
    echo -e "  ${CYAN}--stop-all${NC}   Stop all dev-runner instances"
    echo -e "  ${CYAN}--help, -h${NC}   Show this help"
    echo ""
}

case "${1:-}" in
    --status)
        if check_running; then show_status; else
            echo -e "${YELLOW}No running instance for this project${NC}"; exit 1
        fi ;;
    --logs)     cmd_logs ;;
    --stop)     cmd_stop ;;
    --restart)  cmd_restart ;;
    --build)    cmd_build ;;
    --list)     cmd_list ;;
    --stop-all) cmd_stop_all ;;
    --help|-h)  cmd_help ;;
    "")         cmd_start ;;
    *)
        echo -e "${RED}Unknown command: $1${NC}"
        cmd_help
        exit 1 ;;
esac
