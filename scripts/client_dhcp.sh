#!/usr/bin/env bash
# ==============================================================================
# REAL IPTV MULTICAST TEST LAB - LAN DHCP CLIENT MANAGER
# Manages DHCP client requests inside STB client containers to obtain IPs from DUT LAN.
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
  all           Both client containers (Default)
  1 | client1   First client (CLIENT1_NAME)
  2 | client2   Second client (CLIENT2_NAME)
  <name>        Explicit container name

Examples:
  sudo ./scripts/client_dhcp.sh request all
  sudo ./scripts/client_dhcp.sh daemon 1
  ./scripts/client_dhcp.sh status all
USAGE
}

resolve_client_target() {
    local target="$1"
    case "${target}" in
        1|client1|"${CLIENT1_NAME}")
            printf '%s:%s\n' "${CLIENT1_NAME}" "${CLIENT1_HOSTNAME}"
            ;;
        2|client2|"${CLIENT2_NAME}")
            printf '%s:%s\n' "${CLIENT2_NAME}" "${CLIENT2_HOSTNAME}"
            ;;
        *)
            printf '%s:%s\n' "${target}" "${target}"
            ;;
    esac
}

request_lease() {
    local name="$1"
    local hostname="$2"
    local pidfile="${STATE_DIR}/udhcpc-${name}.pid"
    local logfile="${LOG_DIR}/udhcpc-${name}.log"

    require_root
    require_cmd udhcpc
    container_exists "${name}" || die "Container '${name}' is not running. Run ./scripts/setup.sh first."

    local pid
    pid="$(container_pid "${name}")"
    [[ -n "${pid}" && "${pid}" -gt 0 ]] || die "Could not get PID for container '${name}'"

    stop_pidfile "${pidfile}"

    local -a extra_opts=()
    if [[ -n "${hostname}" ]]; then
        extra_opts+=(-x "hostname:${hostname}" -F "${hostname}")
        docker exec "${name}" hostname "${hostname}" 2>/dev/null || true
    fi
    if [[ -n "${CLIENT_DHCP_VENDOR:-}" ]]; then
        extra_opts+=(-V "${CLIENT_DHCP_VENDOR}")
    fi

    log_info "Requesting DHCP lease for ${name} (Host: '${hostname}', Vendor: '${CLIENT_DHCP_VENDOR:-<none>}') on eth0..."

    if nsenter -t "${pid}" -n udhcpc \
        -i eth0 \
        -n -q \
        -t 5 -T 2 \
        -s "${SCRIPT_DIR}/lib/udhcpc.script" \
        -p "${pidfile}" \
        "${extra_opts[@]}" \
        >"${logfile}" 2>&1; then
        local ip_addr gw
        ip_addr="$(docker exec "${name}" ip -4 -o addr show dev eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)"
        gw="$(docker exec "${name}" ip route show default 2>/dev/null | awk '{print $3}' | head -n1 || true)"
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
    container_exists "${name}" || die "Container '${name}' is not running. Run ./scripts/setup.sh first."

    local pid
    pid="$(container_pid "${name}")"
    [[ -n "${pid}" && "${pid}" -gt 0 ]] || die "Could not get PID for container '${name}'"

    stop_pidfile "${pidfile}"

    local -a extra_opts=()
    if [[ -n "${hostname}" ]]; then
        extra_opts+=(-x "hostname:${hostname}" -F "${hostname}")
        docker exec "${name}" hostname "${hostname}" 2>/dev/null || true
    fi
    if [[ -n "${CLIENT_DHCP_VENDOR:-}" ]]; then
        extra_opts+=(-V "${CLIENT_DHCP_VENDOR}")
    fi

    log_info "Starting udhcpc background daemon in ${name} (Host: '${hostname}', Vendor: '${CLIENT_DHCP_VENDOR:-<none>}')..."

    nohup nsenter -t "${pid}" -n udhcpc \
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
    ip_addr="$(docker exec "${name}" ip -4 -o addr show dev eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)"
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

    if container_exists "${name}"; then
        docker exec "${name}" ip -4 addr flush dev eth0 2>/dev/null || true
        docker exec "${name}" ip -4 route flush dev eth0 2>/dev/null || true
    fi
    log_info "Released DHCP lease and flushed IP for ${name}."
}

show_status() {
    local name="$1"
    local pidfile="${STATE_DIR}/udhcpc-${name}.pid"

    if ! container_exists "${name}"; then
        printf '  %-15s : Container not running\n' "${name}"
        return 0
    fi

    local status="STATIC / NO DHCP DAEMON"
    if is_pidfile_running "${pidfile}"; then
        status="DHCP DAEMON (PID $(cat "${pidfile}"))"
    fi

    local ip_addr gw mac host
    ip_addr="$(docker exec "${name}" ip -4 -o addr show dev eth0 2>/dev/null | awk '{print $4}' | head -n1 || echo '<no-ip>')"
    gw="$(docker exec "${name}" ip route show default 2>/dev/null | awk '{print $3}' | head -n1 || echo '<none>')"
    mac="$(docker exec "${name}" cat /sys/class/net/eth0/address 2>/dev/null || echo '<unknown>')"
    host="$(docker exec "${name}" hostname 2>/dev/null || echo '<default>')"

    printf '  %-15s | Host: %-16s | MAC: %s | IP: %-15s | GW: %-15s | %s\n' \
        "${name}" "${host}" "${mac}" "${ip_addr}" "${gw}" "${status}"
}

run_on_target() {
    local action="$1"
    local target="${2:-all}"
    local explicit_hostname="${3:-}"

    local -a clients=()
    if [[ "${target}" == "all" ]]; then
        clients=("${CLIENT1_NAME}:${CLIENT1_HOSTNAME}" "${CLIENT2_NAME}:${CLIENT2_HOSTNAME}")
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
