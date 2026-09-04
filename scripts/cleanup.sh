#!/usr/bin/env bash
# ==============================================================================
# REAL IPTV MULTICAST TEST LAB - CLEANUP
# Idempotently tears down containers, veths, netns, bridges, standalone daemons,
# and restores physical interfaces to UP state with DHCP.
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
    cat <<'USAGE'
Usage:
  sudo ./scripts/cleanup.sh [options]

Options:
  -r, --restore, --dhcp    Restore physical interfaces (WAN_IF, LAN_IF) to UP, re-enable NetworkManager,
                           and trigger DHCP [Default]
  -d, --down, --no-restore Keep physical interfaces DOWN and flushed (isolated test mode)
  -h, --help               Show this help message
USAGE
}

main() {
    for arg in "$@"; do
        if [[ "${arg}" == "-h" || "${arg}" == "--help" ]]; then
            usage
            exit 0
        fi
    done

    require_root
    load_config

    local restore="${RESTORE_INTERFACES_ON_CLEANUP:-1}"

    while (( $# > 0 )); do
        case "$1" in
            -r|--restore|--dhcp)    restore=1; shift ;;
            -d|--down|--no-restore) restore=0; shift ;;
            *)                      usage; exit 2 ;;
        esac
    done

    log_info "Initiating cleanup of IPTV Multicast Lab (restore_interfaces=${restore})..."

    # 1. Stop capture and streaming daemon processes (direct and container)
    if [[ -x "${SCRIPT_DIR}/capture.sh" ]]; then
        "${SCRIPT_DIR}/capture.sh" stop 2>/dev/null || true
    fi

    # Direct host streamer
    stop_pidfile "${STATE_DIR}/server_direct.pid"
    pkill -f "udp://${MCAST_GROUP}:${MCAST_PORT}" 2>/dev/null || true

    # Direct WAN DHCP server
    direct_wan_dhcp_server stop 2>/dev/null || true

    # Container daemons
    stop_pidfile "${STATE_DIR}/server.pid"
    stop_pidfile "${STATE_DIR}/client_1.pid"
    stop_pidfile "${STATE_DIR}/client_2.pid"

    # Container WAN DHCP server
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

    # 5. Delete test bridges before restoring physical NICs
    for br in "${WAN_BRIDGE}" "${LAN_BRIDGE}"; do
        if bridge_exists "${br}"; then
            ip link set dev "${br}" down 2>/dev/null || true
            ip link del dev "${br}" 2>/dev/null || true
        fi
    done

    # 6. Restore physical interfaces to UP + DHCP (or keep them DOWN if requested)
    for ifname in "${WAN_IF}" "${LAN_IF}"; do
        if [[ -n "${ifname}" ]] && iface_exists_root "${ifname}"; then
            if (( restore == 1 )); then
                restore_physical_interface "${ifname}"
            else
                tear_down_physical_interface "${ifname}"
            fi
        fi
    done

    # 7. Clean runtime state files
    rm -f "${STATE_DIR}"/*.pid "${STATE_DIR}"/*.state "${STATE_DIR}"/*.txt "${STATE_DIR}/topology_state.env" 2>/dev/null || true

    log_info "Cleanup completed successfully."
}

main "$@"
