#!/usr/bin/env bash
# ==============================================================================
# REAL IPTV MULTICAST TEST LAB - VLC CLIENT MANAGER
# Starts VLC media receiver inside client namespaces to trigger real IGMP Join.
# Supports interactive running ('run') and background daemon ('start' / 'stop').
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
    cat <<'USAGE'
Usage:
  sudo ./scripts/start_client.sh [1|2] [command]

Commands:
  run             Run VLC receiver interactively in foreground [Default if TTY]
  start           Run VLC receiver in background daemon mode
  stop            Stop background VLC receiver
  status          Show status of VLC receiver and IGMP group membership
USAGE
}

get_client_name() {
    local client_id="$1"
    case "${client_id}" in
        1) printf '%s\n' "${CLIENT1_NAME}" ;;
        2) printf '%s\n' "${CLIENT2_NAME}" ;;
        *) die "Invalid client ID '${client_id}'. Use 1 or 2." ;;
    esac
}

get_client_user() {
    local user="${SUDO_USER:-}"
    if [[ -z "${user}" || "${user}" == "root" ]]; then
        user="$(awk -F: '$3 >= 1000 && $3 < 65534 {print $1; exit}' /etc/passwd 2>/dev/null || echo "nobody")"
    fi
    printf '%s\n' "${user}"
}

run_foreground() {
    local id="$1"
    local name
    name="$(get_client_name "${id}")"
    local user
    user="$(get_client_user)"

    require_root
    require_cmd cvlc
    netns_exists "${name}" || die "Namespace '${name}' is not running. Run sudo ./scripts/setup.sh first."

    log_info "Starting VLC receiver in ${name} as ${user} (Foreground) for ${MCAST_GROUP}:${MCAST_PORT}..."
    ip netns exec "${name}" runuser -u "${user}" -- cvlc -I dummy --no-audio --vout=dummy --no-video-title-show "udp://@${MCAST_GROUP}:${MCAST_PORT}"
}

start_background() {
    local id="$1"
    local name
    name="$(get_client_name "${id}")"
    local user
    user="$(get_client_user)"
    local pidfile="${STATE_DIR}/client_${id}.pid"
    local logfile="${LOG_DIR}/client_${id}.log"

    require_root
    require_cmd cvlc
    netns_exists "${name}" || die "Namespace '${name}' is not running. Run sudo ./scripts/setup.sh first."

    if is_pidfile_running "${pidfile}"; then
        log_warn "Client ${id} (${name}) already running (PID $(cat "${pidfile}"))."
        return 0
    fi

    log_info "Starting background VLC receiver in ${name} as ${user} for ${MCAST_GROUP}:${MCAST_PORT}..."
    nohup ip netns exec "${name}" runuser -u "${user}" -- cvlc -I dummy --no-audio --vout=dummy --no-video-title-show "udp://@${MCAST_GROUP}:${MCAST_PORT}" \
        >"${logfile}" 2>&1 &

    local pid=$!
    printf '%s\n' "${pid}" > "${pidfile}"
    sleep 0.5

    if ! kill -0 "${pid}" 2>/dev/null; then
        log_error "Failed to start VLC receiver in ${name}."
        cat "${logfile}" >&2 || true
        rm -f "${pidfile}"
        return 1
    fi

    log_info "VLC receiver in ${name} started [PID ${pid}]. Logs: ${logfile}"
}

stop_background() {
    local id="$1"
    local name
    name="$(get_client_name "${id}")"
    local pidfile="${STATE_DIR}/client_${id}.pid"

    require_root
    if is_pidfile_running "${pidfile}"; then
        local pid
        pid="$(cat "${pidfile}")"
        log_info "Stopping VLC receiver in ${name} [PID ${pid}]..."
        stop_pidfile "${pidfile}"
    else
        rm -f "${pidfile}" 2>/dev/null || true
    fi

    # Terminate VLC inside namespace gracefully to trigger IGMP Leave signaling
    if netns_exists "${name}"; then
        ip netns exec "${name}" pkill -TERM -f vlc 2>/dev/null || true
        sleep 0.2
        ip netns exec "${name}" pkill -KILL -f vlc 2>/dev/null || true
    fi
    log_info "VLC receiver in ${name} stopped."
}

show_status() {
    local id="$1"
    local name
    name="$(get_client_name "${id}")"
    local pidfile="${STATE_DIR}/client_${id}.pid"

    printf '== Client %s (%s) Status ==\n' "${id}" "${name}"
    if is_pidfile_running "${pidfile}"; then
        printf 'Status:     RUNNING (PID %s)\n' "$(cat "${pidfile}")"
    else
        printf 'Status:     STOPPED\n'
    fi

    if netns_exists "${name}"; then
        local ip_addr
        ip_addr="$(ip netns exec "${name}" ip -4 -o addr show dev eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)"
        printf 'IP Address: %s\n' "${ip_addr:-<none>}"
        printf 'Multicast Groups Joined:\n'
        ip netns exec "${name}" ip maddr show dev eth0 2>/dev/null | awk '/inet / {print "  - " $2}' || true
    fi
}

main() {
    load_config
    local client_id="${1:-1}"
    local cmd="${2:-}"

    # Handle syntax like: start_client.sh status 1
    if [[ "${client_id}" =~ ^(run|start|stop|status)$ ]]; then
        cmd="${client_id}"
        client_id="${2:-1}"
    fi

    if [[ -z "${cmd}" ]]; then
        if [[ -t 0 ]]; then
            cmd="run"
        else
            cmd="start"
        fi
    fi

    case "${cmd}" in
        run)    run_foreground "${client_id}" ;;
        start)  start_background "${client_id}" ;;
        stop)   stop_background "${client_id}" ;;
        status) show_status "${client_id}" ;;
        -h|--help) usage ;;
        *)      usage; exit 2 ;;
    esac
}

main "$@"
