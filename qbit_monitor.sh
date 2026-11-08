#!/usr/bin/env bash
# ============================================================
# qbit_monitor.sh — NordVPN WireGuard server monitor (HOST-RESIDENT)
# Runs on the Docker HOST (not inside the container) as a
# systemd service. Watches tunnel reachability inside the
# "qbit" container, switches to a new NordVPN server if the
# tunnel stays down, writes a new wg0.conf on the host
# (bind-mounted into the container), cycles wg-quick inside
# the container via `docker exec`, and restarts the container
# directly if the tunnel still doesn't come back.
#
# Rationale for moving off the container: the container's
# kill-switch firewall rules drop ALL outbound traffic that
# isn't routed through wg0 — including traffic explicitly
# bound to eth0 via `curl --interface eth0`. Interface binding
# only selects the source interface; it does not exempt the
# packet from OUTPUT/FORWARD DROP rules. When the tunnel is
# down, that "escape hatch" is exactly what the kill switch is
# designed to block, so the API call inside the container can
# silently fail. Running this on the host avoids that entirely.
# ============================================================

# ------------------------------------------------------------
# LOCAL MONITORING
# ------------------------------------------------------------
# systemctl status qbit-monitor
# journalctl -u qbit-monitor -f


# ------------------------------------------------------------
# TOGGLES
# ------------------------------------------------------------
LOGGING=true          # Master switch: write to log file at all
DRY_RUN=false         # If true, log actions but do not write configs / touch docker

# Log verbosity — controls what goes to log AND stdout
# ERROR   : failures and critical events only
# INFO    : + startup banner, tunnel state changes, server switches  [default]
# VERBOSE : + every ping check result, config write details
# DEBUG   : + raw API responses, validation steps, all state changes
LOG_LEVEL="INFO"

# ------------------------------------------------------------
# TUNNEL CONFIG
# ------------------------------------------------------------
FAILURES_BEFORE_SWITCH=5     # Consecutive failures before acting
MAX_SWITCH_ATTEMPTS=5        # Max wg0.conf writes AND max container restarts (shared cap)
CHECK_INTERVAL=300           # Seconds between tunnel checks
WG_QUICK_WAIT=30             # Seconds to wait after wg-quick down/up before re-testing

# ------------------------------------------------------------
# PING CONFIG (executed inside the container via docker exec,
# since wg0 only exists in the container's netns)
# ------------------------------------------------------------
PING_HOST="1.1.1.1"
DOCKER_INTERFACE_CUSTOM=true  # true  = pin the reachability ping to DOCKER_INTERFACE via -I
                               # false = no -I flag; let the container's own routing table pick the interface naturally
DOCKER_INTERFACE="wg0"        # Interface name used when DOCKER_INTERFACE_CUSTOM=true (e.g. wg0, eth0, or any other
                               # interface present inside the container). Ignored entirely when CUSTOM=false.
PING_COUNT=1
PING_TIMEOUT=10

# ------------------------------------------------------------
# DOCKER
# ------------------------------------------------------------
CONTAINER_NAME="qbit"
DOCKER_EXEC_TIMEOUT=20        # Seconds before we give up on a docker exec call

# ------------------------------------------------------------
# FILES (all HOST paths now)
# ------------------------------------------------------------
WG_CONF="/dl/docker/volumes/qb-config/_data/wireguard/wg0.conf"
WG_CONF_TMP="${WG_CONF}.tmp"
LOG_DIR="/dvr/qb/logs"           # Host log directory
FLAG_DIR="${LOG_DIR}/wg"         # Flag file directory
LOG_FILE="${LOG_DIR}/qbit_monitor.log"
LOG_MAX_BYTES=2097152            # Rotate at 2 MB
LOG_MAX_BACKUPS=5                # Number of rotated log backups to keep
MAX_BACKUPS=12                   # Number of wg0.conf backups to keep

# Persistent counter/flag files -- survive service restarts
SWITCH_ATTEMPTS_FILE="${FLAG_DIR}/switch_attempts"      # How many times wg0.conf has been written
RESTART_ATTEMPTS_FILE="${FLAG_DIR}/restart_attempts"    # How many container restarts issued
RESTART_FAILURE_FILE="${FLAG_DIR}/restart_wgfailure"    # Terminal failure flag -- container stopped, needs manual clear

# PID file — prevents duplicate instances (defense-in-depth alongside systemd)
PID_FILE="/tmp/qbit-monitor.pid"

# ------------------------------------------------------------
# API / NETWORK
# ------------------------------------------------------------
NORD_API="https://api.nordvpn.com/v1/servers/recommendations"
COUNTRY_ID="228"             # 228 = United States
CURL_TIMEOUT=15
HOST_INTERFACE="eth0"        # Host's own outbound interface for the API call

# ------------------------------------------------------------
# BINARIES
# ------------------------------------------------------------
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# ============================================================
# DIRECTORIES
# ============================================================
mkdir -p "$LOG_DIR"
mkdir -p "$FLAG_DIR"

# ============================================================
# LOGGING
# ============================================================
_level_rank() {
    case "$1" in
        ERROR)   echo 0 ;;
        INFO)    echo 1 ;;
        VERBOSE) echo 2 ;;
        DEBUG)   echo 3 ;;
        *)       echo 1 ;;
    esac
}

_log() {
    local level="$1"; shift
    local want_rank cur_rank
    want_rank=$(_level_rank "$level")
    cur_rank=$(_level_rank "$LOG_LEVEL")
    (( want_rank > cur_rank )) && return 0

    local ts msg
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    msg="[$ts] [$(printf '%-7s' "$level")] $*"

    echo "$msg"

    [[ "$LOGGING" != true ]] && return 0

    [[ ! -f "$LOG_FILE" ]] && touch "$LOG_FILE"

    local size
    size=$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
    if (( size >= LOG_MAX_BYTES )); then
        local i
        for (( i=LOG_MAX_BACKUPS; i>=1; i-- )); do
            local older=$(( i - 1 ))
            local src="${LOG_FILE}.${older}"
            local dst="${LOG_FILE}.${i}"
            [[ "$older" -eq 0 ]] && src="$LOG_FILE"
            if [[ -f "$src" ]]; then
                if (( i <= LOG_MAX_BACKUPS )); then
                    mv "$src" "$dst"
                else
                    rm -f "$src"
                fi
            fi
        done
        echo "[$ts] [INFO   ] Log rotated" >> "$LOG_FILE"
    fi

    echo "$msg" >> "$LOG_FILE"
}

log_error()   { _log "ERROR"   "$@"; }
log_info()    { _log "INFO"    "$@"; }
log_verbose() { _log "VERBOSE" "$@"; }
log_debug()   { _log "DEBUG"   "$@"; }

# ============================================================
# PID FILE — prevent duplicate instances
# ============================================================
cleanup_pid() {
    rm -f "$PID_FILE"
}

if [[ -f "$PID_FILE" ]]; then
    EXISTING_PID=$(cat "$PID_FILE" 2>/dev/null)
    if [[ -n "$EXISTING_PID" ]] && kill -0 "$EXISTING_PID" 2>/dev/null; then
        log_error "Another instance is already running (PID ${EXISTING_PID}) — exiting"
        exit 1
    else
        log_debug "Stale PID file found (PID ${EXISTING_PID}) — cleaning up"
        rm -f "$PID_FILE"
    fi
fi

echo $$ > "$PID_FILE"

# ============================================================
# STRICT MODE + ERR TRAP
# ============================================================
set -Eeuo pipefail
[[ "$LOG_LEVEL" == "DEBUG" ]] && trap 'log_error "Line $LINENO exited with status $?"' ERR

# ============================================================
# CLEANUP — runs on any exit
# ============================================================
cleanup() {
    rm -f "$WG_CONF_TMP"
    cleanup_pid
    log_info "qbit_monitor.sh exited"
}
trap cleanup EXIT

# ============================================================
# PERSISTENT COUNTER HELPERS
# ============================================================
read_counter() {
    local file="$1"
    if [[ -f "$file" ]]; then
        local val
        val=$(cat "$file" 2>/dev/null | tr -d '[:space:]')
        [[ "$val" =~ ^[0-9]+$ ]] && echo "$val" || echo 0
    else
        echo 0
    fi
}

write_counter() {
    local file="$1" val="$2"
    echo "$val" > "$file"
}

increment_counter() {
    local file="$1"
    local current
    current=$(read_counter "$file")
    local new=$(( current + 1 ))
    write_counter "$file" "$new"
    echo "$new"
}

clear_flag_files() {
    rm -f "$SWITCH_ATTEMPTS_FILE" "$RESTART_ATTEMPTS_FILE"
    log_info "Persistent counters cleared — tunnel recovered"
}

# ============================================================
# FAILURE STATE CHECK — exit immediately if terminal failure
# ============================================================
if [[ -f "$RESTART_FAILURE_FILE" ]]; then
    log_error "restart_wgfailure flag exists — container was stopped after repeated failures"
    log_error "Delete ${RESTART_FAILURE_FILE} and restart the service manually to recover"
    exit 1
fi

# ============================================================
# CONTAINER HELPERS
# ============================================================
container_running() {
    [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null)" == "true" ]]
}

docker_exec() {
    timeout "$DOCKER_EXEC_TIMEOUT" docker exec "$CONTAINER_NAME" "$@"
}

# ============================================================
# BANNER
# ============================================================
SWITCH_ATTEMPTS_NOW=$(read_counter "$SWITCH_ATTEMPTS_FILE")
RESTART_ATTEMPTS_NOW=$(read_counter "$RESTART_ATTEMPTS_FILE")

log_info "============================================"
log_info "qbit_monitor.sh started (host-resident)"
log_info "  LOG_LEVEL=$LOG_LEVEL  LOGGING=$LOGGING  DRY_RUN=$DRY_RUN"
log_info "  Container               : $CONTAINER_NAME"
log_info "  Log file                : $LOG_FILE"
log_info "  wg0.conf (host path)    : $WG_CONF"
log_info "  FAILURES_BEFORE_SWITCH  : $FAILURES_BEFORE_SWITCH"
log_info "  MAX_SWITCH_ATTEMPTS     : $MAX_SWITCH_ATTEMPTS"
log_info "  CHECK_INTERVAL          : ${CHECK_INTERVAL}s"
log_info "  WG_QUICK_WAIT           : ${WG_QUICK_WAIT}s"
log_info "  HOST_INTERFACE          : $HOST_INTERFACE"
log_info "  switch_attempts         : ${SWITCH_ATTEMPTS_NOW}/${MAX_SWITCH_ATTEMPTS} (persistent)"
log_info "  restart_attempts        : ${RESTART_ATTEMPTS_NOW}/${MAX_SWITCH_ATTEMPTS} (persistent)"
log_debug "  PID_FILE       : $PID_FILE"
log_debug "  PID            : $$"
log_debug "  LOG_DIR        : $LOG_DIR"
log_debug "  FLAG_DIR       : $FLAG_DIR"
log_verbose "  PING_HOST      : $PING_HOST"
log_verbose "  DOCKER_INTERFACE_CUSTOM : $DOCKER_INTERFACE_CUSTOM"
log_verbose "  DOCKER_INTERFACE : $DOCKER_INTERFACE"
log_verbose "  PING_COUNT     : $PING_COUNT"
log_verbose "  PING_TIMEOUT   : $PING_TIMEOUT"
log_verbose "  CURL_TIMEOUT   : $CURL_TIMEOUT"
log_verbose "  MAX_BACKUPS    : $MAX_BACKUPS"
log_info "============================================"

case "$DOCKER_INTERFACE_CUSTOM" in
    true|false) ;;
    *)
        log_error "Invalid DOCKER_INTERFACE_CUSTOM '${DOCKER_INTERFACE_CUSTOM}' — must be true or false"
        exit 1
        ;;
esac

if [[ "$DOCKER_INTERFACE_CUSTOM" == true && -z "$DOCKER_INTERFACE" ]]; then
    log_error "DOCKER_INTERFACE_CUSTOM=true but DOCKER_INTERFACE is empty"
    exit 1
fi

# ============================================================
# VALIDATION HELPERS
# ============================================================
is_valid_ip() {
    local ip="$1"
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    local IFS='.'
    read -ra octets <<< "$ip"
    for octet in "${octets[@]}"; do
        (( octet >= 0 && octet <= 255 )) || return 1
    done
}

is_valid_pubkey() {
    local key="$1"
    [[ ${#key} -eq 44 && "$key" =~ ^[A-Za-z0-9+/]{43}=$ ]]
}

# ============================================================
# REACHABILITY (must run inside the container's netns)
# ============================================================
is_unreachable() {
    if ! container_running; then
        log_error "Container ${CONTAINER_NAME} is not running"
        return 0
    fi

    local -a ping_cmd=(ping -c "$PING_COUNT" -W "$PING_TIMEOUT")
    if [[ "$DOCKER_INTERFACE_CUSTOM" == true ]]; then
        ping_cmd+=(-I "$DOCKER_INTERFACE")
    fi
    ping_cmd+=("$PING_HOST")

    ! docker_exec "${ping_cmd[@]}" &>/dev/null
}

# ============================================================
# API (runs directly on the HOST — not behind the container's
# kill-switch firewall, so this no longer needs an escape hatch)
# ============================================================
fetch_best_server() {
    local raw result
    log_debug "Fetching server from NordVPN API via $HOST_INTERFACE..."
    raw=$(curl -sf --max-time "$CURL_TIMEOUT" --interface "$HOST_INTERFACE" \
        "${NORD_API}?filters\[servers_technologies\]\[identifier\]=wireguard_udp&filters\[country_id\]=${COUNTRY_ID}&limit=1" \
        2>/dev/null) || {
        log_error "curl failed fetching server list"
        echo ""
        return
    }

    log_debug "API raw response length: ${#raw} bytes"

    result=$(echo "$raw" | jq -r '
        .[0] |
        .station as $ip |
        (.technologies[] | select(.identifier=="wireguard_udp") | .metadata[] | select(.name=="public_key") | .value) as $pubkey |
        "\($ip)|\($pubkey)"
    ' 2>/dev/null) || {
        log_error "jq failed parsing server response"
        echo ""
        return
    }

    echo "$result"
}

# ============================================================
# BACKUP ROTATION (host path)
# ============================================================
rotate_backups() {
    for (( i=MAX_BACKUPS-1; i>=1; i-- )); do
        [[ -f "${WG_CONF}.${i}" ]] && mv "${WG_CONF}.${i}" "${WG_CONF}.$((i+1))"
    done
    cp "$WG_CONF" "${WG_CONF}.1"
    log_info "Config backup created: ${WG_CONF}.1"
}

# ============================================================
# CONFIG WRITER (writes directly to the host path, which is
# bind-mounted into the container — no docker exec needed)
# ============================================================
write_new_conf() {
    local new_ip="$1" new_pubkey="$2"

    local postup postdown address listenport privatekey
    postup=$(grep    -m1 'PostUp'      "$WG_CONF" | awk -F" = " '{print $2}' || true)
    postdown=$(grep  -m1 'PostDown'    "$WG_CONF" | awk -F" = " '{print $2}' || true)
    address=$(grep   -m1 'Address'     "$WG_CONF" | awk -F' = ' '{print $2}' || true)
    listenport=$(grep -m1 'ListenPort' "$WG_CONF" | awk -F' = ' '{print $2}' || true)
    privatekey=$(grep -m1 'PrivateKey' "$WG_CONF" | awk -F' = ' '{print $2}' || true)

    log_verbose "write_new_conf: new_ip=${new_ip}"
    log_verbose "write_new_conf: address=${address} listenport=${listenport}"

    if [[ -z "$address" || -z "$listenport" || -z "$privatekey" ]]; then
        log_error "Missing required Interface fields — aborting config write"
        return 1
    fi

    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY-RUN] Would write new config: endpoint=${new_ip}:51820 pubkey=${new_pubkey}"
        return 0
    fi

    {
        echo "[Interface]"
        [[ -n "$postup"   ]] && echo "PostUp = ${postup}"
        [[ -n "$postdown" ]] && echo "PostDown = ${postdown}"
        echo "Address = ${address}"
        echo "ListenPort = ${listenport}"
        echo "PrivateKey = ${privatekey}"
        echo "#Table = off"
        echo ""
        echo "[Peer]"
        echo "PublicKey = ${new_pubkey}"
        echo "AllowedIPs = 0.0.0.0/0"
        echo "Endpoint = ${new_ip}:51820"
        echo "PersistentKeepalive = 25"
    } > "$WG_CONF_TMP"

    if ! grep -q '\[Interface\]' "$WG_CONF_TMP" || \
       ! grep -q '\[Peer\]'      "$WG_CONF_TMP" || \
       ! grep -q 'PrivateKey'    "$WG_CONF_TMP" || \
       ! grep -q 'PublicKey'     "$WG_CONF_TMP" || \
       ! grep -q '^Endpoint'     "$WG_CONF_TMP"; then
        log_error "Temp config failed validation — original wg0.conf preserved"
        rm -f "$WG_CONF_TMP"
        return 1
    fi

    rotate_backups
    mv "$WG_CONF_TMP" "$WG_CONF"
    log_info "wg0.conf updated — new endpoint: ${new_ip}:51820"
}

# ============================================================
# TERMINAL FAILURE — host stops the container directly
# ============================================================
declare_failure() {
    log_error "======================================================"
    log_error "TERMINAL FAILURE — stopping ${CONTAINER_NAME} and writing restart_wgfailure flag"
    log_error "Delete ${RESTART_FAILURE_FILE} and restart the service to recover"
    log_error "======================================================"
    if [[ "$DRY_RUN" != true ]]; then
        docker stop "$CONTAINER_NAME" 2>/dev/null || log_error "docker stop ${CONTAINER_NAME} failed"
        touch "$RESTART_FAILURE_FILE"
    fi
    exit 1
}

# ============================================================
# MAIN LOOP
# ============================================================
CONSECUTIVE_FAILURES=0

while true; do
    if [[ "$DOCKER_INTERFACE_CUSTOM" == true ]]; then
        log_verbose "Pinging ${PING_HOST} via ${DOCKER_INTERFACE} inside ${CONTAINER_NAME} (count=${PING_COUNT} timeout=${PING_TIMEOUT}s)"
    else
        log_verbose "Pinging ${PING_HOST} via default routing inside ${CONTAINER_NAME} (count=${PING_COUNT} timeout=${PING_TIMEOUT}s)"
    fi

    if is_unreachable; then
        CONSECUTIVE_FAILURES=$(( CONSECUTIVE_FAILURES + 1 ))
        log_info "Tunnel unreachable (consecutive: ${CONSECUTIVE_FAILURES}/${FAILURES_BEFORE_SWITCH})"
    else
        if (( CONSECUTIVE_FAILURES > 0 )); then
            log_info "Tunnel recovered — resetting failure counter"
            clear_flag_files
        else
            log_verbose "Tunnel OK"
        fi
        CONSECUTIVE_FAILURES=0
    fi

    if (( CONSECUTIVE_FAILURES >= FAILURES_BEFORE_SWITCH )); then

        # ── Check persistent switch counter ──────────────────
        SWITCH_ATTEMPTS=$(read_counter "$SWITCH_ATTEMPTS_FILE")
        if (( SWITCH_ATTEMPTS >= MAX_SWITCH_ATTEMPTS )); then
            log_error "Max wg0.conf write attempts (${MAX_SWITCH_ATTEMPTS}) reached"
            declare_failure
        fi

        # ── Fetch new server (host, direct) ──────────────────
        log_info "Failure threshold reached — fetching new server via ${HOST_INTERFACE}..."
        SERVER_INFO=$(fetch_best_server)

        if [[ -z "$SERVER_INFO" ]]; then
            log_error "Could not fetch server info — will retry next cycle"
            sleep "$CHECK_INTERVAL"
            continue
        fi

        NEW_IP=$(echo "$SERVER_INFO"     | cut -d'|' -f1)
        NEW_PUBKEY=$(echo "$SERVER_INFO" | cut -d'|' -f2)
        log_debug "Candidate server: ip=${NEW_IP} pubkey=${NEW_PUBKEY}"

        if ! is_valid_ip "$NEW_IP"; then
            log_error "Invalid IP '${NEW_IP}' — will retry next cycle"
            sleep "$CHECK_INTERVAL"
            continue
        fi

        if ! is_valid_pubkey "$NEW_PUBKEY"; then
            log_error "Invalid PublicKey '${NEW_PUBKEY}' — will retry next cycle"
            sleep "$CHECK_INTERVAL"
            continue
        fi

        # ── Write wg0.conf (host path) ────────────────────────
        log_info "Writing new wg0.conf (attempt $(( SWITCH_ATTEMPTS + 1 ))/${MAX_SWITCH_ATTEMPTS})..."
        if ! write_new_conf "$NEW_IP" "$NEW_PUBKEY"; then
            log_error "Config write failed — will retry next cycle"
            sleep "$CHECK_INTERVAL"
            continue
        fi
        increment_counter "$SWITCH_ATTEMPTS_FILE" > /dev/null
        log_info "switch_attempts now: $(read_counter "$SWITCH_ATTEMPTS_FILE")/${MAX_SWITCH_ATTEMPTS}"

        # ── Cycle wg-quick inside the container ──────────────
        log_info "Cycling WireGuard interface inside ${CONTAINER_NAME} (wg-quick down/up)..."
        if ! container_running; then
            log_error "Container ${CONTAINER_NAME} not running — cannot cycle wg-quick"
        elif docker_exec wg-quick down wg0 2>/dev/null; then
            log_info "wg-quick down: OK"
        else
            log_error "wg-quick down: failed (continuing anyway)"
        fi

        if container_running; then
            if docker_exec wg-quick up wg0 2>/dev/null; then
                log_info "wg-quick up: OK"
            else
                log_error "wg-quick up: failed"
            fi
        fi

        # ── Wait then test ───────────────────────────────────
        log_info "Waiting ${WG_QUICK_WAIT}s for tunnel to stabilise..."
        sleep "$WG_QUICK_WAIT"

        log_info "Testing tunnel after wg-quick cycle..."
        if ! is_unreachable; then
            log_info "Tunnel recovered after wg-quick cycle — SUCCESS"
            clear_flag_files
            CONSECUTIVE_FAILURES=0
            sleep "$CHECK_INTERVAL"
            continue
        fi

        # ── Tunnel still down — restart the container directly ─
        log_error "Tunnel still down after wg-quick cycle"

        RESTART_COUNT=$(read_counter "$RESTART_ATTEMPTS_FILE")
        NEW_RESTART_COUNT=$(( RESTART_COUNT + 1 ))

        if (( NEW_RESTART_COUNT > MAX_SWITCH_ATTEMPTS )); then
            log_error "Max container restarts (${MAX_SWITCH_ATTEMPTS}) reached"
            declare_failure
        fi

        write_counter "$RESTART_ATTEMPTS_FILE" "$NEW_RESTART_COUNT"
        log_error "Restarting ${CONTAINER_NAME} (${NEW_RESTART_COUNT}/${MAX_SWITCH_ATTEMPTS})..."
        if [[ "$DRY_RUN" == true ]]; then
            log_info "[DRY-RUN] Would run: docker restart ${CONTAINER_NAME}"
        elif docker restart "$CONTAINER_NAME" 2>/dev/null; then
            log_info "docker restart ${CONTAINER_NAME}: OK"
        else
            log_error "docker restart ${CONTAINER_NAME}: failed"
        fi

        sleep "$CHECK_INTERVAL"
    fi

    sleep "$CHECK_INTERVAL"
done
