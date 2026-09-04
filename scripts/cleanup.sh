#!/usr/bin/env bash
# ==============================================================================
# REAL IPTV MULTICAST TEST LAB - CLEANUP
# Idempotently tears down containers, veths, netns, bridges, and background jobs
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

main() {
    require_root
    load_config

    log_info "Initiating cleanup of IPTV Multicast Lab..."

    # 1. Stop capture and daemon processes
    if [[ -x "${SCRIPT_DIR}/capture.sh" ]]; then
        "${SCRIPT_DIR}/capture.sh" stop 2>/dev/null || true
    fi

    stop_pidfile "${STATE_DIR}/server.pid"
    stop_pidfile "${STATE_DIR}/client_1.pid"
    stop_pidfile "${STATE_DIR}/client_2.pid"

    # Stop WAN DHCP server
    wan_dhcp_server stop 2>/dev/null || true

    # 2. Stop and remove Docker containers
    if command -v docker >/dev/null 2>&1; then
        for name in "${CLIENT1_NAME}" "${CLIENT2_NAME}" "${SERVER_NAME}"; do
            if container_exists "${name}"; then
                docker rm -f "${name}" >/dev/null 2>&1 || true
            fi
        done
    fi

    # 3. Delete virtual interfaces
    for v in veth-mserv veth-mc1 veth-mc2 veth-wan-ctl v-dut-wan-h v-dut-lan-h; do
        ip link del "${v}" 2>/dev/null || true
    done

    # 4. Delete network namespaces
    for ns in "${WAN_NS}" "ns-dut"; do
        if ns_exists "${ns}"; then
            ip netns del "${ns}" 2>/dev/null || true
        fi
    done

    # 5. Detach physical interfaces and bring them down safely
    for ifname in "${WAN_IF}" "${LAN_IF}"; do
        if [[ -n "${ifname}" ]] && iface_exists_root "${ifname}"; then
            ip link set dev "${ifname}" nomaster 2>/dev/null || true
            ip addr flush dev "${ifname}" 2>/dev/null || true
            ip link set dev "${ifname}" down 2>/dev/null || true
        fi
    done

    # 6. Delete test bridges
    for br in "${WAN_BRIDGE}" "${LAN_BRIDGE}"; do
        if bridge_exists "${br}"; then
            ip link set dev "${br}" down 2>/dev/null || true
            ip link del dev "${br}" 2>/dev/null || true
        fi
    done

    # 7. Clean runtime state files
    rm -f "${STATE_DIR}"/*.pid "${STATE_DIR}"/hostname-*.txt "${STATE_DIR}/topology_state.env" 2>/dev/null || true

    log_info "Cleanup completed successfully."
}

main "$@"
