#!/usr/bin/env bash
# ==============================================================================
# REAL IPTV MULTICAST TEST LAB - LAN DHCP CLIENT MANAGER
# Manages DHCP client requests inside STB client namespaces to obtain IPs from DUT LAN.
# Supports DHCP Option 12 (Hostname) and Option 60 (Vendor Class Identifier).
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
load_config

usage() {
    cat <<'USAGE'
Usage:
  sudo ./scripts/client_dhcp.sh [action] [target] [hostname]

Actions:
  request  [client|all] [hostname]  One-shot DHCP lease request
  daemon   [client|all] [hostname]  Start background udhcpc daemon to maintain lease
  release  [client|all]             Release DHCP lease and flush IP
  status   [client|all]             Show assigned IP, hostname, MAC, and lease status

Targets:
  all           All STB client namespaces (Default)
  <N> | client<N> Client index (e.g. 1, 2, 3...)
  <name>        Explicit namespace name (e.g. ns-stb3)

Examples:
  sudo ./scripts/client_dhcp.sh request all
  sudo ./scripts/client_dhcp.sh daemon 1
  ./scripts/client_dhcp.sh status all
USAGE
}

resolve_client_target() {
    local target="$1"
    if [[ "${target}" =~ ^([0-9]+)$ ]]; then
        local idx="${BASH_REMATCH[1]}"
        printf '%s:%s\n' "$(get_client_name "${idx}")" "$(get_client_hostname "${idx}")"
    elif [[ "${target}" =~ ^client([0-9]+)$ ]]; then
        local idx="${BASH_REMATCH[1]}"
        printf '%s:%s\n' "$(get_client_name "${idx}")" "$(get_client_hostname "${idx}")"
    else
        local count
        count="$(get_client_count)"
        local i found=0
        for (( i=1; i<=count; i++ )); do
            local cname
            cname="$(get_client_name "${i}")"
            if [[ "${target}" == "${cname}" ]]; then
                printf '%s:%s\n' "${cname}" "$(get_client_hostname "${i}")"
                found=1
                break
            fi
        done
        if (( found == 0 )); then
            printf '%s:%s\n' "${target}" "${target}"
        fi
    fi
}

request_lease() {
    local name="$1"
    local hostname="$2"
    local pidfile="${STATE_DIR}/udhcpc-${name}.pid"
    local logfile="${LOG_DIR}/udhcpc-${name}.log"

    require_root
    require_cmd udhcpc
    netns_exists "${name}" || die "Namespace '${name}' is not running. Run sudo ./scripts/setup.sh first."

    stop_pidfile "${pidfile}"

    local -a extra_opts=()
    if [[ -n "${hostname}" ]]; then
        extra_opts+=(-x "hostname:${hostname}" -F "${hostname}")
        printf '%s\n' "${hostname}" > "${STATE_DIR}/hostname-${name}.txt"
    fi
    if [[ -n "${CLIENT_DHCP_VENDOR:-}" ]]; then
        extra_opts+=(-V "${CLIENT_DHCP_VENDOR}")
    fi

    log_info "Requesting DHCP lease for ${name} (Host: '${hostname}', Vendor: '${CLIENT_DHCP_VENDOR:-<none>}') on eth0..."

    if env CLIENT_NETNS="${name}" STATE_DIR="${STATE_DIR}" ip netns exec "${name}" udhcpc \
        -i eth0 \
        -n -q \
        -t 5 -T 2 \
        -s "${SCRIPT_DIR}/lib/udhcpc.script" \
        -p "${pidfile}" \
        "${extra_opts[@]}" \
        >"${logfile}" 2>&1; then
        local ip_addr gw
        ip_addr="$(ip -n "${name}" -4 -o addr show dev eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)"
        gw="$(ip netns exec "${name}" ip route show default 2>/dev/null | awk '{print $3}' | head -n1 || true)"
        [[ -n "${ip_addr}" ]] && printf '%s\n' "${ip_addr}" > "${STATE_DIR}/ip-${name}.txt" 2>/dev/null || true
        [[ -n "${gw}" ]] && printf '%s\n' "${gw}" > "${STATE_DIR}/gw-${name}.txt" 2>/dev/null || true
        log_info "SUCCESS: ${name} (${hostname}) leased IP ${ip_addr:-<unknown>} from DUT LAN (Gateway: ${gw:-<none>})"
    else
        log_warn "Failed to obtain DHCP lease for ${name} (${hostname}). Ensure DUT LAN DHCP server is active."
        tail -n 10 "${logfile}" >&2 || true
        return 1
    fi
}

start_daemon() {
    local name="$1"
    local hostname="$2"
    local pidfile="${STATE_DIR}/udhcpc-${name}.pid"
    local logfile="${LOG_DIR}/udhcpc-${name}.log"

    require_root
    require_cmd udhcpc
    netns_exists "${name}" || die "Namespace '${name}' is not running. Run sudo ./scripts/setup.sh first."

    stop_pidfile "${pidfile}"

    local -a extra_opts=()
    if [[ -n "${hostname}" ]]; then
        extra_opts+=(-x "hostname:${hostname}" -F "${hostname}")
        printf '%s\n' "${hostname}" > "${STATE_DIR}/hostname-${name}.txt"
    fi
    if [[ -n "${CLIENT_DHCP_VENDOR:-}" ]]; then
        extra_opts+=(-V "${CLIENT_DHCP_VENDOR}")
    fi

    log_info "Starting udhcpc background daemon in ${name} (Host: '${hostname}', Vendor: '${CLIENT_DHCP_VENDOR:-<none>}')..."

    nohup env CLIENT_NETNS="${name}" STATE_DIR="${STATE_DIR}" ip netns exec "${name}" udhcpc \
        -i eth0 \
        -b \
        -t 10 -T 3 \
        -s "${SCRIPT_DIR}/lib/udhcpc.script" \
        -p "${pidfile}" \
        "${extra_opts[@]}" \
        >"${logfile}" 2>&1 &

    local bg_pid=$!
    sleep 0.5
    local ip_addr
    ip_addr="$(ip -n "${name}" -4 -o addr show dev eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)"
    log_info "${name} (${hostname}) udhcpc daemon started [PID $(cat "${pidfile}" 2>/dev/null || echo "${bg_pid}")], IP: ${ip_addr:-waiting...}"
}

release_lease() {
    local name="$1"
    local pidfile="${STATE_DIR}/udhcpc-${name}.pid"

    require_root
    if is_pidfile_running "${pidfile}"; then
        kill -USR2 "$(cat "${pidfile}")" 2>/dev/null || true
        stop_pidfile "${pidfile}"
    fi

    if netns_exists "${name}"; then
        ip -n "${name}" -4 addr flush dev eth0 2>/dev/null || true
        ip -n "${name}" -4 route flush dev eth0 2>/dev/null || true
    fi
    log_info "Released DHCP lease and flushed IP for ${name}."
}

show_status() {
    local name="$1"
    local pidfile="${STATE_DIR}/udhcpc-${name}.pid"

    if ! netns_exists "${name}"; then
        printf '  %-15s : Namespace not running\n' "${name}"
        return 0
    fi

    local status="STATIC / NO DHCP DAEMON"
    if is_pidfile_running "${pidfile}"; then
        status="DHCP DAEMON (PID $(cat "${pidfile}"))"
    fi

    local ip_addr="" gw="" mac="" host=""
    host="$(cat "${STATE_DIR}/hostname-${name}.txt" 2>/dev/null || echo '<default>')"

    # 1. Live query from kernel (requires root / sudo)
    if is_root; then
        ip_addr="$(ip -n "${name}" -4 -o addr show dev eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)"
        gw="$(ip netns exec "${name}" ip route show default 2>/dev/null | awk '{print $3}' | head -n1 || true)"
        mac="$(ip -n "${name}" link show dev eth0 2>/dev/null | awk '/link\/ether/ {print $2}' || true)"

        [[ -n "${ip_addr}" ]] && printf '%s\n' "${ip_addr}" > "${STATE_DIR}/ip-${name}.txt" 2>/dev/null || true
        [[ -n "${gw}" ]] && printf '%s\n' "${gw}" > "${STATE_DIR}/gw-${name}.txt" 2>/dev/null || true
        [[ -n "${mac}" ]] && printf '%s\n' "${mac}" > "${STATE_DIR}/mac-${name}.txt" 2>/dev/null || true
    fi

    # 2. Resilient fallbacks for non-root query or unqueried fields
    if [[ -z "${mac}" ]]; then
        mac="$(cat "${STATE_DIR}/mac-${name}.txt" 2>/dev/null || true)"
    fi
    if [[ -z "${mac}" && "${name}" =~ ([0-9]+)$ ]]; then
        mac="$(get_client_mac "${BASH_REMATCH[1]}")"
    fi

    if [[ -z "${ip_addr}" ]]; then
        ip_addr="$(cat "${STATE_DIR}/ip-${name}.txt" 2>/dev/null || true)"
    fi
    if [[ -z "${ip_addr}" && -f "${LOG_DIR}/udhcpc-${name}.log" ]]; then
        ip_addr="$(awk '/lease of/ {for(i=1;i<=NF;i++) if($i=="of") print $(i+1)}' "${LOG_DIR}/udhcpc-${name}.log" 2>/dev/null | tr -d ',' | tail -n1 || true)"
    fi

    if [[ -z "${gw}" ]]; then
        gw="$(cat "${STATE_DIR}/gw-${name}.txt" 2>/dev/null || true)"
    fi
    if [[ -z "${gw}" && -f "${LOG_DIR}/udhcpc-${name}.log" ]]; then
        gw="$(awk '/obtained from/ {for(i=1;i<=NF;i++) if($i=="from") print $(i+1)}' "${LOG_DIR}/udhcpc-${name}.log" 2>/dev/null | tr -d ',' | tail -n1 || true)"
    fi

    ip_addr="${ip_addr:-<no-ip>}"
    gw="${gw:-<none>}"
    mac="${mac:-<unknown>}"

    printf '  %-15s | Host: %-16s | MAC: %s | IP: %-15s | GW: %-15s | %s\n' \
        "${name}" "${host}" "${mac}" "${ip_addr}" "${gw}" "${status}"
}

run_on_target() {
    local action="$1"
    local target="${2:-all}"
    local explicit_hostname="${3:-}"

    local -a clients=()
    if [[ "${target}" == "all" ]]; then
        local names
        names="$(get_active_client_names)"
        local idx=1
        while read -r ns; do
            [[ -z "${ns}" ]] && continue
            local host
            if [[ "${ns}" =~ ([0-9]+)$ ]]; then
                host="$(get_client_hostname "${BASH_REMATCH[1]}")"
            else
                host="$(get_client_hostname "${idx}")"
            fi
            clients+=("${ns}:${host}")
            (( idx++ ))
        done <<< "${names}"
    else
        clients=("$(resolve_client_target "${target}")")
    fi

    for pair in "${clients[@]}"; do
        local name="${pair%%:*}"
        local default_host="${pair##*:}"
        local hostname="${explicit_hostname:-${default_host}}"

        case "${action}" in
            request) request_lease "${name}" "${hostname}" || true ;;
            daemon)  start_daemon "${name}" "${hostname}" || true ;;
            release) release_lease "${name}" ;;
            status)  show_status "${name}" ;;
        esac
    done
}

main() {
    for arg in "$@"; do
        if [[ "${arg}" == "-h" || "${arg}" == "--help" ]]; then
            usage
            exit 0
        fi
    done

    load_config
    local action="${1:-status}"
    local target="${2:-all}"
    local explicit_hostname="${3:-}"

    case "${action}" in
        request|daemon|release)
            run_on_target "${action}" "${target}" "${explicit_hostname}"
            ;;
        status)
            printf '== STB Clients DHCP Status ==\n'
            run_on_target "status" "${target}" ""
            ;;
        *)
            usage
            exit 2
            ;;
    esac
}

main "$@"
