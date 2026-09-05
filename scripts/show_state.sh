#!/usr/bin/env bash
# ==============================================================================
# REAL IPTV MULTICAST TEST LAB - SHOW STATE
# Displays runtime state of bridges, network namespaces, streaming daemons, and captures
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

show_namespace_details() {
    local name="$1"
    local role="$2"

    printf '\n-- %s (%s) --\n' "${name}" "${role}"
    if ! netns_exists "${name}"; then
        if [[ "${WAN_ONLY:-0}" == "1" || "${SERVER_ONLY:-0}" == "1" ]] && [[ "${name}" != "${SERVER_NAME}" ]]; then
            printf '  Status: SKIPPED (WAN/Server-Only Mode)\n'
        else
            printf '  Status: NOT RUNNING\n'
        fi
        return 0
    fi

    local ip_addr="" gw="" host="" mac="" ip_mode=""
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
    if [[ -z "${ip_addr}" ]]; then
        if [[ "${name}" == "${SERVER_NAME}" && -n "${SERVER_IP:-}" ]]; then
            ip_addr="${SERVER_IP%/*}"
        elif [[ "${name}" == "${WAN_NS}" && -n "${WAN_NS_IP:-}" ]]; then
            ip_addr="${WAN_NS_IP%/*}"
        fi
    fi

    if [[ -z "${gw}" ]]; then
        gw="$(cat "${STATE_DIR}/gw-${name}.txt" 2>/dev/null || true)"
    fi
    if [[ -z "${gw}" && -f "${LOG_DIR}/udhcpc-${name}.log" ]]; then
        gw="$(awk '/obtained from/ {for(i=1;i<=NF;i++) if($i=="from") print $(i+1)}' "${LOG_DIR}/udhcpc-${name}.log" 2>/dev/null | tr -d ',' | tail -n1 || true)"
    fi
    if [[ -z "${gw}" ]]; then
        if [[ "${name}" == "${SERVER_NAME}" && -n "${SERVER_GW:-}" ]]; then
            gw="${SERVER_GW}"
        elif [[ "${name}" == "${WAN_NS}" && -n "${WAN_NS_GW:-}" ]]; then
            gw="${WAN_NS_GW}"
        fi
    fi

    ip_mode="Static"
    if is_pidfile_running "${STATE_DIR}/udhcpc-${name}.pid"; then
        ip_mode="DHCP Leased (udhcpc PID $(cat "${STATE_DIR}/udhcpc-${name}.pid"))"
    fi

    printf '  Hostname:      %s\n' "${host}"
    printf '  MAC Address:   %s\n' "${mac:-<unknown>}"
    printf '  IP Address:    %s (%s)\n' "${ip_addr:-<no-ip>}" "${ip_mode}"
    printf '  Default Route: via %s\n' "${gw:-<none>}"
    printf '  Multicast Groups Joined:\n'
    local found_mcast=0
    if is_root; then
        while IFS= read -r g; do
            if [[ -n "${g}" ]]; then
                printf '    * %s\n' "${g}"
                found_mcast=1
            fi
        done < <(ip netns exec "${name}" ip maddr show dev eth0 2>/dev/null | awk '/inet / {print $2}' || true)
    fi
    if (( found_mcast == 0 )); then
        if ! is_root; then
            printf '    (Run with sudo to inspect live IGMP memberships)\n'
        else
            printf '    <none>\n'
        fi
    fi
}

show_container_details() { show_namespace_details "$@"; }

main() {
    load_config

    printf '==============================================================================\n'
    printf '                 REAL IPTV MULTICAST LAB - RUNTIME STATE                      \n'
    printf '==============================================================================\n'

    # Check for Standalone Direct WAN Server mode first
    if is_pidfile_running "${STATE_DIR}/server_direct.pid"; then
        printf 'Operating Mode:  Standalone Direct WAN Server (Zero Topology / Direct Host)\n'
        printf 'WAN Interface:   %s (%s)\n' "${WAN_IF}" "$(ip -4 -o addr show dev "${WAN_IF}" 2>/dev/null | awk '{print $4}' | head -n1 || echo '<none>')"
        printf 'Multicast Route: %s\n' "$(ip route show 224.0.0.0/4 2>/dev/null || echo '<none>')"
        printf '\n'
        "${SCRIPT_DIR}/start_server.sh" status || true
        printf '\n'
        "${SCRIPT_DIR}/capture.sh" status || true
        printf '==============================================================================\n'
        return 0
    fi

    local mode="Physical DUT"
    local wan_only=0
    local server_only=0

    if [[ -f "${STATE_DIR}/topology_state.env" ]]; then
        # shellcheck disable=SC1090
        source "${STATE_DIR}/topology_state.env"
        wan_only="${WAN_ONLY:-0}"
        server_only="${SERVER_ONLY:-0}"

        if [[ "${IS_VIRTUAL:-0}" == "1" ]]; then
            mode="Virtual Simulation (ns-dut)"
        fi
        if [[ "${wan_only}" == "1" ]]; then
            mode="Physical DUT [WAN-Only Server]"
        elif [[ "${server_only}" == "1" ]]; then
            mode="${mode} [Server-Only]"
        fi
    fi

    printf 'Operating Mode:  %s\n' "${mode}"

    printf '\n== WAN Bridge & Members (%s) ==\n' "${WAN_BRIDGE}"
    if bridge_exists "${WAN_BRIDGE}"; then
        ip -br link show "${WAN_BRIDGE}" 2>/dev/null || true
        printf 'Bridge Ports:\n'
        ip link show master "${WAN_BRIDGE}" 2>/dev/null | awk -F ': ' '/^[0-9]+:/ {print "  - " $2}' || true
    else
        printf 'Bridge %s: NOT ACTIVE\n' "${WAN_BRIDGE}"
    fi

    if [[ "${wan_only}" == "0" ]]; then
        printf '\n== LAN Bridge & Members (%s) ==\n' "${LAN_BRIDGE}"
        if bridge_exists "${LAN_BRIDGE}"; then
            ip -br link show "${LAN_BRIDGE}" 2>/dev/null || true
            printf 'Bridge Ports:\n'
            ip link show master "${LAN_BRIDGE}" 2>/dev/null | awk -F ': ' '/^[0-9]+:/ {print "  - " $2}' || true
        else
            printf 'Bridge %s: NOT ACTIVE\n' "${LAN_BRIDGE}"
        fi
    fi

    printf '\n== Network Namespaces ==\n'
    show_namespace_details "${SERVER_NAME}" "FFmpeg Multicast Streamer"
    if [[ "${wan_only}" == "0" ]]; then
        local client_names
        client_names="$(get_active_client_names)"
        local idx=1
        while IFS= read -r c_name; do
            [[ -z "${c_name}" ]] && continue
            show_namespace_details "${c_name}" "STB Client ${idx}"
            (( idx++ ))
        done <<< "${client_names}"
    fi

    printf '\n'
    "${SCRIPT_DIR}/start_server.sh" status || true

    printf '\n'
    wan_dhcp_server status || true

    if [[ "${wan_only}" == "0" && "${server_only}" == "0" ]]; then
        printf '\n'
        "${SCRIPT_DIR}/client_dhcp.sh" status all || true
    fi

    printf '\n'
    "${SCRIPT_DIR}/capture.sh" status || true

    printf '==============================================================================\n'
}

main "$@"
