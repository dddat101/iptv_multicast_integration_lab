#!/usr/bin/env bash
# ==============================================================================
# REAL IPTV MULTICAST TEST LAB - SHOW STATE
# Displays runtime state of bridges, docker containers, streaming daemons, and captures
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

show_container_details() {
    local name="$1"
    local role="$2"

    printf '\n-- %s (%s) --\n' "${name}" "${role}"
    if ! container_exists "${name}"; then
        if [[ "${SERVER_ONLY:-0}" == "1" && "${name}" != "${SERVER_NAME}" ]]; then
            printf '  Status: SKIPPED (Server-Only Mode)\n'
        else
            printf '  Status: NOT RUNNING\n'
        fi
        return 0
    fi

    local pid
    pid="$(container_pid "${name}")"
    printf '  Container PID: %s\n' "${pid}"

    local ip_addr gw host
    ip_addr="$(docker exec "${name}" ip -4 -o addr show dev eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)"
    gw="$(docker exec "${name}" ip route show default 2>/dev/null | awk '{print $3}' | head -n1 || true)"
    host="$(docker exec "${name}" hostname 2>/dev/null || echo '<default>')"
    printf '  Hostname:      %s\n' "${host}"
    printf '  IP Address:    %s\n' "${ip_addr:-<no-ip>}"
    printf '  Default Route: via %s\n' "${gw:-<none>}"
    printf '  Multicast Groups Joined:\n'
    while IFS= read -r g; do
        [[ -n "${g}" ]] && printf '    * %s\n' "${g}"
    done < <(docker exec "${name}" ip maddr show dev eth0 2>/dev/null | awk '/inet / {print $2}' || true)
}

main() {
    load_config

    local mode="Physical DUT"
    if [[ -f "${STATE_DIR}/topology_state.env" ]]; then
        # shellcheck disable=SC1090
        source "${STATE_DIR}/topology_state.env"
        if [[ "${IS_VIRTUAL:-0}" == "1" ]]; then
            mode="Virtual Simulation (ns-dut)"
        fi
        if [[ "${SERVER_ONLY:-0}" == "1" ]]; then
            mode="${mode} [Server-Only]"
        fi
    fi

    printf '==============================================================================\n'
    printf '                 REAL IPTV MULTICAST LAB - RUNTIME STATE                      \n'
    printf '==============================================================================\n'
    printf 'Operating Mode:  %s\n' "${mode}"

    printf '\n== WAN Bridge & Members (%s) ==\n' "${WAN_BRIDGE}"
    if bridge_exists "${WAN_BRIDGE}"; then
        ip -br link show "${WAN_BRIDGE}" 2>/dev/null || true
        printf 'Bridge Ports:\n'
        ip link show master "${WAN_BRIDGE}" 2>/dev/null | awk -F ': ' '/^[0-9]+:/ {print "  - " $2}' || true
    else
        printf 'Bridge %s: NOT ACTIVE\n' "${WAN_BRIDGE}"
    fi

    printf '\n== LAN Bridge & Members (%s) ==\n' "${LAN_BRIDGE}"
    if bridge_exists "${LAN_BRIDGE}"; then
        ip -br link show "${LAN_BRIDGE}" 2>/dev/null || true
        printf 'Bridge Ports:\n'
        ip link show master "${LAN_BRIDGE}" 2>/dev/null | awk -F ': ' '/^[0-9]+:/ {print "  - " $2}' || true
    else
        printf 'Bridge %s: NOT ACTIVE\n' "${LAN_BRIDGE}"
    fi

    printf '\n== Docker Application Containers ==\n'
    show_container_details "${SERVER_NAME}" "FFmpeg Multicast Streamer"
    show_container_details "${CLIENT1_NAME}" "VLC STB Client 1"
    show_container_details "${CLIENT2_NAME}" "VLC STB Client 2"

    printf '\n'
    "${SCRIPT_DIR}/start_server.sh" status || true

    printf '\n'
    wan_dhcp_server status || true

    printf '\n'
    "${SCRIPT_DIR}/capture.sh" status || true

    printf '==============================================================================\n'
}

main "$@"
