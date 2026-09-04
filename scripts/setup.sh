#!/usr/bin/env bash
# ==============================================================================
# REAL IPTV MULTICAST TEST LAB - TOPOLOGY SETUP
# Supports Physical DUT mode and Virtual Simulation mode (--virtual / --no-dut)
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

SETUP_ACTIVE=0

rollback_setup() {
    local exit_code="$1"
    local line_no="$2"

    if (( SETUP_ACTIVE == 1 )); then
        log_error "Setup failed at line ${line_no} (exit code: ${exit_code}). Initiating automatic cleanup..."
        "${SCRIPT_DIR}/cleanup.sh" || true
    fi
    exit "${exit_code}"
}

usage() {
    cat <<'USAGE'
Usage:
  sudo ./scripts/setup.sh [options]

Options:
  -p, --physical          Run in Physical DUT mode (requires dedicated USB adapters) [Default]
  -v, --virtual, --no-dut Run in Virtual Simulation mode (self-contained, no physical DUT required)
  -s, --server-only       Deploy Media Server only (skip STB clients) and start streaming immediately
  --no-stream             In server-only mode, do not auto-start streaming
  -h, --help              Show this help message
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
    check_docker

    require_cmd ip
    require_cmd docker
    require_cmd nsenter

    SERVER_ONLY="${SERVER_ONLY:-0}"
    local auto_stream=1

    while (( $# > 0 )); do
        case "$1" in
            --virtual|-v|--no-dut) IS_VIRTUAL=1; shift ;;
            --physical|-p)         IS_VIRTUAL=0; shift ;;
            --server-only|-s)      SERVER_ONLY=1; shift ;;
            --no-stream)           auto_stream=0; shift ;;
            -h|--help)             usage; exit 0 ;;
            *)                     shift ;;
        esac
    done

    # Pre-flight check: Media Image
    if ! docker image inspect "${MEDIA_IMAGE}" >/dev/null 2>&1; then
        log_warn "Docker image '${MEDIA_IMAGE}' not found. Building it automatically..."
        "${SCRIPT_DIR}/build_image.sh"
    fi

    # Pre-flight check: Media sample asset
    if [[ ! -f "${MEDIA_DIR}/${MEDIA_FILE}" ]]; then
        log_warn "Test asset '${MEDIA_DIR}/${MEDIA_FILE}' missing. Generating sample 1080p stream..."
        "${SCRIPT_DIR}/generate_media.sh"
    fi

    # Physical interface safety checks
    if (( IS_VIRTUAL == 0 )); then
        assert_safe_test_if "${WAN_IF}"
        assert_safe_test_if "${LAN_IF}"
        [[ "${WAN_IF}" != "${LAN_IF}" ]] || die "WAN_IF and LAN_IF must differ."
    fi

    SETUP_ACTIVE=1
    trap 'rollback_setup $? ${LINENO}' ERR

    printf '==============================================================================\n'
    printf '        REAL IPTV MULTICAST LAB - SETUP (VIRTUAL: %d)                         \n' "${IS_VIRTUAL}"
    printf '==============================================================================\n'

    log_info "Creating L2 test bridges: ${WAN_BRIDGE} and ${LAN_BRIDGE}..."
    bridge_create "${WAN_BRIDGE}"
    bridge_create "${LAN_BRIDGE}"

    if (( IS_VIRTUAL == 0 )); then
        log_info "Attaching physical interfaces to bridges: ${WAN_IF} -> ${WAN_BRIDGE}, ${LAN_IF} -> ${LAN_BRIDGE}..."
        attach_physical_to_bridge "${WAN_IF}" "${WAN_BRIDGE}"
        attach_physical_to_bridge "${LAN_IF}" "${LAN_BRIDGE}"
    fi

    log_info "Creating WAN control namespace: ${WAN_NS}..."
    if ! ns_exists "${WAN_NS}"; then
        ip netns add "${WAN_NS}"
    fi
    ip -n "${WAN_NS}" link set lo up
    ip link del veth-wan-ctl 2>/dev/null || true
    ip link add veth-wan-ctl type veth peer name vpeer-wan-ctl
    ip link set veth-wan-ctl master "${WAN_BRIDGE}"
    ip link set veth-wan-ctl up
    ip link set vpeer-wan-ctl netns "${WAN_NS}"
    ip -n "${WAN_NS}" link set vpeer-wan-ctl name eth0
    ip -n "${WAN_NS}" addr flush dev eth0 || true
    ip -n "${WAN_NS}" addr add "${WAN_NS_IP}" dev eth0
    ip -n "${WAN_NS}" link set eth0 up

    if [[ "${ENABLE_WAN_DHCP:-0}" == "1" ]]; then
        wan_dhcp_server start
    fi

    log_info "Starting media server container: ${SERVER_NAME} (${SERVER_IP})..."
    start_idle_container "${SERVER_NAME}"
    attach_container_to_bridge "${SERVER_NAME}" "${WAN_BRIDGE}" veth-mserv vpeer-mserv "${SERVER_IP}" "${SERVER_GW}" "mcast-server"

    if (( SERVER_ONLY == 0 )); then
        log_info "Starting client 1 container: ${CLIENT1_NAME} (${CLIENT1_IP}, Hostname: '${CLIENT1_HOSTNAME}')..."
        start_idle_container "${CLIENT1_NAME}"
        attach_container_to_bridge "${CLIENT1_NAME}" "${LAN_BRIDGE}" veth-mc1 vpeer-mc1 "${CLIENT1_IP}" "${CLIENT1_GW}" "${CLIENT1_HOSTNAME}"
        force_container_igmp_version "${CLIENT1_NAME}" "${FORCE_IGMP_VERSION}"

        log_info "Starting client 2 container: ${CLIENT2_NAME} (${CLIENT2_IP}, Hostname: '${CLIENT2_HOSTNAME}')..."
        start_idle_container "${CLIENT2_NAME}"
        attach_container_to_bridge "${CLIENT2_NAME}" "${LAN_BRIDGE}" veth-mc2 vpeer-mc2 "${CLIENT2_IP}" "${CLIENT2_GW}" "${CLIENT2_HOSTNAME}"
        force_container_igmp_version "${CLIENT2_NAME}" "${FORCE_IGMP_VERSION}"
    else
        log_info "Server-only mode: STB client containers skipped."
    fi

    if (( IS_VIRTUAL == 1 )); then
        setup_virtual_dut
    fi

    if (( SERVER_ONLY == 1 && auto_stream == 1 )); then
        log_info "Auto-starting media server streaming on ${SERVER_NAME}..."
        "${SCRIPT_DIR}/start_server.sh" start
    fi

    cat >"${STATE_DIR}/topology_state.env" <<EOF
IS_VIRTUAL='${IS_VIRTUAL}'
SERVER_ONLY='${SERVER_ONLY}'
WAN_BRIDGE='${WAN_BRIDGE}'
LAN_BRIDGE='${LAN_BRIDGE}'
WAN_IF='${WAN_IF}'
LAN_IF='${LAN_IF}'
WAN_NS='${WAN_NS}'
SERVER_NAME='${SERVER_NAME}'
CLIENT1_NAME='${CLIENT1_NAME}'
CLIENT2_NAME='${CLIENT2_NAME}'
EOF

    SETUP_ACTIVE=0
    trap - ERR
    log_info "Setup completed successfully (virtual=${IS_VIRTUAL}, server_only=${SERVER_ONLY})."
}

main "$@"
