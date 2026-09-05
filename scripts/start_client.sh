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
  sudo ./scripts/start_client.sh [target] [command]

Targets:
  <N> | client<N> Client index (e.g. 1, 2, 3...) [Default: 1]
  <name>          Explicit namespace name (e.g. ns-stb1)
  all             All active STB client namespaces (for start, stop, status)

Commands:
  run             Run VLC receiver interactively in foreground [Default if TTY]
  start           Run VLC receiver in background daemon mode
  stop            Stop background VLC receiver
  status          Show status of VLC receiver and IGMP group membership

Examples:
  sudo ./scripts/start_client.sh 1 run
  sudo ./scripts/start_client.sh all start
  sudo ./scripts/start_client.sh all status
  sudo ./scripts/start_client.sh all stop
USAGE
}

resolve_client_name() {
    local target="$1"
    if [[ "${target}" =~ ^([0-9]+)$ ]]; then
        get_client_name "${BASH_REMATCH[1]}"
    elif [[ "${target}" =~ ^client([0-9]+)$ ]]; then
        get_client_name "${BASH_REMATCH[1]}"
    else
        printf '%s\n' "${target}"
    fi
}

get_client_user() {
    local user="${SUDO_USER:-}"
    if [[ -z "${user}" || "${user}" == "root" ]]; then
        user="$(awk -F: '$3 >= 1000 && $3 < 65534 {print $1; exit}' /etc/passwd 2>/dev/null || echo "nobody")"
    fi
    printf '%s\n' "${user}"
}

run_foreground() {
    local name="$1"
    local user
    user="$(get_client_user)"

    require_root
    require_cmd cvlc
    netns_exists "${name}" || die "Namespace '${name}' is not running. Run sudo ./scripts/setup.sh first."

    log_info "Starting VLC receiver in ${name} as ${user} (Foreground) for ${MCAST_GROUP}:${MCAST_PORT}..."
    ip netns exec "${name}" runuser -u "${user}" -- cvlc -I dummy --no-audio --vout=dummy --no-video-title-show "udp://@${MCAST_GROUP}:${MCAST_PORT}"
}

start_background() {
    local name="$1"
    local user
    user="$(get_client_user)"
    local pidfile="${STATE_DIR}/client_${name}.pid"
    local logfile="${LOG_DIR}/client_${name}.log"

    require_root
    require_cmd cvlc
    netns_exists "${name}" || die "Namespace '${name}' is not running. Run sudo ./scripts/setup.sh first."

    if is_pidfile_running "${pidfile}"; then
        log_warn "Client ${name} already running (PID $(cat "${pidfile}"))."
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
    local name="$1"
    local pidfile="${STATE_DIR}/client_${name}.pid"

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
    local name="$1"
    local pidfile="${STATE_DIR}/client_${name}.pid"

    printf '== Client %s Status ==\n' "${name}"
    if is_pidfile_running "${pidfile}"; then
        printf 'Status:     RUNNING (PID %s)\n' "$(cat "${pidfile}")"
    else
        printf 'Status:     STOPPED\n'
    fi

    if netns_exists "${name}"; then
        local ip_addr=""
        if is_root; then
            ip_addr="$(ip -n "${name}" -4 -o addr show dev eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)"
            [[ -n "${ip_addr}" ]] && printf '%s\n' "${ip_addr}" > "${STATE_DIR}/ip-${name}.txt" 2>/dev/null || true
        fi
        if [[ -z "${ip_addr}" ]]; then
            ip_addr="$(cat "${STATE_DIR}/ip-${name}.txt" 2>/dev/null || true)"
        fi
        if [[ -z "${ip_addr}" && -f "${LOG_DIR}/udhcpc-${name}.log" ]]; then
            ip_addr="$(awk '/lease of/ {for(i=1;i<=NF;i++) if($i=="of") print $(i+1)}' "${LOG_DIR}/udhcpc-${name}.log" 2>/dev/null | tr -d ',' | tail -n1 || true)"
        fi
        printf 'IP Address: %s\n' "${ip_addr:-<none>}"
        printf 'Multicast Groups Joined:\n'
        local found=0
        if is_root; then
            while IFS= read -r g; do
                [[ -n "${g}" ]] && printf '  - %s\n' "${g}" && found=1
            done < <(ip netns exec "${name}" ip maddr show dev eth0 2>/dev/null | awk '/inet / {print $2}' || true)
        fi
        if (( found == 0 )); then
            if ! is_root; then
                printf '  (Run with sudo to inspect live IGMP memberships)\n'
            else
                printf '  <none>\n'
            fi
        fi
    else
        printf 'Namespace:  Not found\n'
    fi
}

main() {
    for arg in "$@"; do
        if [[ "${arg}" == "-h" || "${arg}" == "--help" ]]; then
            usage
            exit 0
        fi
    done

    load_config
    local target="${1:-1}"
    local cmd="${2:-}"

    # Handle syntax like: start_client.sh status 1
    if [[ "${target}" =~ ^(run|start|stop|status)$ ]]; then
        cmd="${target}"
        target="${2:-1}"
    fi

    if [[ -z "${cmd}" ]]; then
        if [[ -t 0 && "${target}" != "all" ]]; then
            cmd="run"
        else
            cmd="start"
        fi
    fi

    if [[ "${target}" == "all" ]]; then
        [[ "${cmd}" != "run" ]] || die "Foreground interactive mode 'run' cannot be used with target 'all'."
        local active_names
        active_names="$(get_active_client_names)"
        while read -r c_name; do
            [[ -z "${c_name}" ]] && continue
            case "${cmd}" in
                start)  start_background "${c_name}" ;;
                stop)   stop_background "${c_name}" ;;
                status) show_status "${c_name}" ;;
            esac
        done <<< "${active_names}"
        return 0
    fi

    local client_name
    client_name="$(resolve_client_name "${target}")"

    case "${cmd}" in
        run)    run_foreground "${client_name}" ;;
        start)  start_background "${client_name}" ;;
        stop)   stop_background "${client_name}" ;;
        status) show_status "${client_name}" ;;
        -h|--help) usage ;;
        *)      usage; exit 2 ;;
    esac
}

main "$@"
