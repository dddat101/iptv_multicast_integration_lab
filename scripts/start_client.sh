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
Description:
  Manages VLC (cvlc) IPTV client instances inside STB network namespaces.
  Joins multicast groups via native kernel IP_ADD_MEMBERSHIP socket options,
  receiving MPEG-TS video streams and generating standard IGMPv2 Reports/Leaves.

Usage:
  sudo ./scripts/start_client.sh [options] [target] [command]
  ./scripts/start_client.sh -h | --help

Targets:
  <N> | client<N> Client index (e.g. 1, 2, 3...) [Default: 1]
  <name>          Explicit namespace name (e.g. ns-stb1)
  all             All active STB client namespaces (for start, stop, status)

Commands:
  run             Run VLC receiver interactively in foreground [Default if TTY]
  start           Run VLC receiver in background daemon mode
  stop            Stop background VLC receiver
  status          Show status of VLC receiver and IGMP/MLD group membership

Options:
  -4, --ipv4      Join IPv4 multicast stream (default: 239.10.10.10)
  -6, --ipv6      Join IPv6 multicast stream (default: ff0e::10:10:10)
  --dual, --dual-stack, -ds
                  Join both IPv4 and IPv6 multicast streams concurrently
  -g, --group <ip> Override multicast destination group
  -p, --port <port> Override UDP destination port
  -h, --help      Show this help message and exit

Examples:
  sudo ./scripts/start_client.sh 1 run
  sudo ./scripts/start_client.sh 1 start
  sudo ./scripts/start_client.sh -6 1 start
  sudo ./scripts/start_client.sh --dual 1 start
  sudo ./scripts/start_client.sh all start
  sudo ./scripts/start_client.sh --dual all start
  ./scripts/start_client.sh all status
  sudo ./scripts/start_client.sh all stop

Suggested Next Steps:
  - Verify compliance:     ./scripts/verify_compliance.sh
  - Run benchmark suite:   sudo ./scripts/benchmark_suite.sh all
  - Inspect lab state:     ./scripts/show_state.sh
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

get_vlc_target_url() {
    local group="$1"
    local port="$2"
    if [[ "${group}" =~ : ]]; then
        printf '[%s]:%s' "${group}" "${port}"
    else
        printf '%s:%s' "${group}" "${port}"
    fi
}

run_foreground() {
    local name="$1"
    local user
    user="$(get_client_user)"

    require_root
    require_cmd cvlc
    netns_exists "${name}" || die "Namespace '${name}' is not running. Run sudo ./scripts/setup.sh first."

    if [[ "${MCAST_GROUP}" =~ : || "${IP_VERSION:-4}" == "6" ]]; then
        wait_for_ipv6_dad "${name}" eth0 5
        ip -n "${name}" -6 route replace ff00::/8 dev eth0 2>/dev/null || true
    fi

    local url_target
    url_target="$(get_vlc_target_url "${MCAST_GROUP}" "${MCAST_PORT}")"
    log_info "Starting VLC receiver in ${name} as ${user} (Foreground) for ${url_target}..."
    ip netns exec "${name}" runuser -u "${user}" -- cvlc -I dummy --no-audio --vout=dummy --no-video-title-show "udp://@${url_target}"
}

start_background() {
    local name="$1"
    local user
    user="$(get_client_user)"
    local pidfile="${STATE_DIR}/client_${name}.pid"
    local logfile="${LOG_DIR}/client_${name}.log"
    local pidfile6="${STATE_DIR}/client_${name}_v6.pid"
    local logfile6="${LOG_DIR}/client_${name}_v6.log"

    require_root
    require_cmd cvlc
    netns_exists "${name}" || die "Namespace '${name}' is not running. Run sudo ./scripts/setup.sh first."

    if [[ "${IP_VERSION:-4}" == "dual" || "${IP_VERSION:-4}" == "dual-stack" || "${IP_VERSION:-4}" == "ds" ]]; then
        local start_v4=1 start_v6=1
        if is_pidfile_running "${pidfile}"; then
            log_warn "Client ${name} IPv4 receiver already running (PID $(cat "${pidfile}"))."
            start_v4=0
        fi
        if is_pidfile_running "${pidfile6}"; then
            log_warn "Client ${name} IPv6 receiver already running (PID $(cat "${pidfile6}"))."
            start_v6=0
        fi

        if (( start_v4 == 1 )); then
            local grp4="${MCAST_GROUP:-239.10.10.10}"
            local url_v4="${grp4}:${MCAST_PORT:-5000}"
            log_info "Starting background IPv4 VLC receiver in ${name} as ${user} for udp://@${url_v4}..."
            nohup ip netns exec "${name}" runuser -u "${user}" -- cvlc -I dummy --no-audio --vout=dummy --no-video-title-show "udp://@${url_v4}" \
                >"${logfile}" 2>&1 &
            local pid4=$!
            printf '%s\n' "${pid4}" > "${pidfile}"
        fi

        if (( start_v6 == 1 )); then
            wait_for_ipv6_dad "${name}" eth0 5
            ip -n "${name}" -6 route replace ff00::/8 dev eth0 2>/dev/null || true
            local grp6="${MCAST_GROUP6:-ff0e::10:10:10}"
            local url_v6="[${grp6}]:${MCAST_PORT:-5000}"
            log_info "Starting background IPv6 VLC receiver in ${name} as ${user} for udp://@${url_v6}..."
            nohup ip netns exec "${name}" runuser -u "${user}" -- cvlc -I dummy --no-audio --vout=dummy --no-video-title-show "udp://@${url_v6}" \
                >"${logfile6}" 2>&1 &
            local pid6=$!
            printf '%s\n' "${pid6}" > "${pidfile6}"
        fi

        sleep 0.5
        if (( start_v4 == 1 )) && ! kill -0 "$(cat "${pidfile}" 2>/dev/null || echo 0)" 2>/dev/null; then
            log_error "Failed to start IPv4 VLC receiver in ${name}."
            cat "${logfile}" >&2 || true
            rm -f "${pidfile}"
            return 1
        fi
        if (( start_v6 == 1 )) && ! kill -0 "$(cat "${pidfile6}" 2>/dev/null || echo 0)" 2>/dev/null; then
            log_error "Failed to start IPv6 VLC receiver in ${name}."
            cat "${logfile6}" >&2 || true
            rm -f "${pidfile6}"
            return 1
        fi
        local v4_pid v6_pid
        v4_pid="$(cat "${pidfile}" 2>/dev/null || echo '<none>')"
        v6_pid="$(cat "${pidfile6}" 2>/dev/null || echo '<none>')"
        log_info "Client ${name} Dual-Stack VLC receiver running (IPv4 PID ${v4_pid}, IPv6 PID ${v6_pid})"
        return 0
    fi

    if is_pidfile_running "${pidfile}"; then
        log_warn "Client ${name} already running (PID $(cat "${pidfile}"))."
        return 0
    fi

    if [[ "${MCAST_GROUP}" =~ : || "${IP_VERSION:-4}" == "6" ]]; then
        wait_for_ipv6_dad "${name}" eth0 5
        ip -n "${name}" -6 route replace ff00::/8 dev eth0 2>/dev/null || true
    fi

    local url_target
    url_target="$(get_vlc_target_url "${MCAST_GROUP}" "${MCAST_PORT}")"
    log_info "Starting background VLC receiver in ${name} as ${user} for ${url_target}..."
    nohup ip netns exec "${name}" runuser -u "${user}" -- cvlc -I dummy --no-audio --vout=dummy --no-video-title-show "udp://@${url_target}" \
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
    local pidfile6="${STATE_DIR}/client_${name}_v6.pid"

    require_root
    local stopped=0
    if is_pidfile_running "${pidfile}"; then
        stop_pidfile "${pidfile}"
        stopped=1
    else
        rm -f "${pidfile}" 2>/dev/null || true
    fi

    if is_pidfile_running "${pidfile6}"; then
        stop_pidfile "${pidfile6}"
        stopped=1
    else
        rm -f "${pidfile6}" 2>/dev/null || true
    fi

    if netns_exists "${name}"; then
        ip netns exec "${name}" pkill -TERM -f cvlc 2>/dev/null || true
        sleep 0.2
        ip netns exec "${name}" pkill -KILL -f cvlc 2>/dev/null || true
    fi

    if (( stopped == 1 )); then
        log_info "Client ${name} stopped."
    else
        log_info "Client ${name} is not running."
    fi
}

show_status() {
    local name="$1"
    local pidfile="${STATE_DIR}/client_${name}.pid"
    local pidfile6="${STATE_DIR}/client_${name}_v6.pid"

    printf '== Client %s Status ==\n' "${name}"
    local st4="STOPPED" st6="STOPPED"
    if is_pidfile_running "${pidfile}"; then
        st4="RUNNING (PID $(cat "${pidfile}"))"
    fi
    if is_pidfile_running "${pidfile6}"; then
        st6="RUNNING (PID $(cat "${pidfile6}"))"
    fi

    if [[ "${IP_VERSION:-4}" == "dual" || "${IP_VERSION:-4}" == "dual-stack" || "${IP_VERSION:-4}" == "ds" ]]; then
        printf 'Status IPv4: %s\n' "${st4}"
        printf 'Status IPv6: %s\n' "${st6}"
    else
        if [[ "${IP_VERSION:-4}" == "6" ]]; then
            printf 'Status:     %s\n' "${st6}"
        else
            printf 'Status:     %s\n' "${st4}"
        fi
    fi

    if netns_exists "${name}"; then
        local ip_addr="" ip6_addr=""
        if is_root; then
            ip_addr="$(ip -n "${name}" -4 -o addr show dev eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)"
            ip6_addr="$(ip -n "${name}" -6 -o addr show dev eth0 2>/dev/null | awk '{print $4}' | grep -v '^fe80' | cut -d/ -f1 | head -n1 || true)"
            [[ -n "${ip_addr}" ]] && printf '%s\n' "${ip_addr}" > "${STATE_DIR}/ip-${name}.txt" 2>/dev/null || true
            [[ -n "${ip6_addr}" ]] && printf '%s\n' "${ip6_addr}" > "${STATE_DIR}/ip6-${name}.txt" 2>/dev/null || true
        else
            ip_addr="$(cat "${STATE_DIR}/ip-${name}.txt" 2>/dev/null || true)"
            ip6_addr="$(cat "${STATE_DIR}/ip6-${name}.txt" 2>/dev/null || true)"
        fi

        if [[ "${IP_VERSION:-4}" == "dual" || "${IP_VERSION:-4}" == "dual-stack" || "${IP_VERSION:-4}" == "ds" ]]; then
            printf 'IPv4 Address: %s\n' "${ip_addr:-<none>}"
            printf 'IPv6 Address: %s\n' "${ip6_addr:-<none>}"
        elif [[ "${IP_VERSION:-4}" == "6" ]]; then
            printf 'IP Address: %s\n' "${ip6_addr:-<none>}"
        else
            printf 'IP Address: %s\n' "${ip_addr:-<none>}"
        fi

        printf 'Multicast Groups Joined:\n'
        local found=0
        if is_root; then
            while IFS= read -r g; do
                [[ -n "${g}" ]] && printf '  - %s\n' "${g}" && found=1
            done < <(ip netns exec "${name}" ip maddr show dev eth0 2>/dev/null | awk '/inet(6)? / {print $2}' || true)
        fi
        if (( found == 0 )); then
            if ! is_root; then
                printf '  (Run with sudo to inspect live memberships)\n'
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
    if [[ -f "${STATE_DIR}/topology_state.env" ]]; then
        local saved_proto saved_mcast saved_mcast6
        saved_proto="$(grep '^IP_VERSION=' "${STATE_DIR}/topology_state.env" 2>/dev/null | cut -d= -f2 | tr -d "'\"" || true)"
        saved_mcast="$(grep '^MCAST_GROUP=' "${STATE_DIR}/topology_state.env" 2>/dev/null | cut -d= -f2 | tr -d "'\"" || true)"
        saved_mcast6="$(grep '^MCAST_GROUP6=' "${STATE_DIR}/topology_state.env" 2>/dev/null | cut -d= -f2 | tr -d "'\"" || true)"
        [[ -n "${saved_proto}" ]] && IP_VERSION="${saved_proto}"
        [[ -n "${saved_mcast}" ]] && MCAST_GROUP="${saved_mcast}"
        [[ -n "${saved_mcast6}" ]] && MCAST_GROUP6="${saved_mcast6}"
    fi

    local target=""
    local cmd=""

    while (( $# > 0 )); do
        case "$1" in
            -4|--ipv4|--ip4)           IP_VERSION="4"; shift ;;
            -6|--ipv6|--ip6)           IP_VERSION="6"; shift ;;
            --dual|--dual-stack|-ds|-2) IP_VERSION="dual"; shift ;;
            -g|--group)
                shift
                [[ $# -gt 0 ]] || die "Missing group value"
                MCAST_GROUP="$1"
                shift
                ;;
            -p|--port)
                shift
                [[ $# -gt 0 ]] || die "Missing port value"
                MCAST_PORT="$1"
                shift
                ;;
            run|start|stop|status)
                cmd="$1"
                shift
                ;;
            -h|--help)
                usage; exit 0 ;;
            *)
                if [[ -z "${target}" ]]; then
                    target="$1"
                else
                    cmd="$1"
                fi
                shift
                ;;
        esac
    done

    target="${target:-1}"
    if [[ "${MCAST_GROUP}" =~ : && "${IP_VERSION:-4}" != "dual" ]]; then
        IP_VERSION="6"
    fi

    # Handle syntax like: start_client.sh status 1
    if [[ "${target}" =~ ^(run|start|stop|status)$ && -z "${cmd}" ]]; then
        cmd="${target}"
        target="1"
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
        *)      usage; exit 2 ;;
    esac
}

main "$@"
