#!/usr/bin/env bash
# ==============================================================================
# REAL IPTV MULTICAST TEST LAB - TOPOLOGY SETUP
# Supports Physical DUT mode, Virtual Simulation mode (--virtual),
# WAN-only mode (--wan-only), and Server-only mode (--server-only).
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
  -w, --wan-only          Deploy WAN side only (WAN bridge, WAN DHCP & Server; skips LAN_IF and clients)
  -s, --server-only       Deploy Media Server only (skip STB client namespaces)
  -n, --clients <count>   Number of STB client namespaces to emulate (default: CLIENT_COUNT in config.env)
  --dhcp, --client-dhcp   Have STB clients obtain dynamic IP from DUT LAN DHCP [Default if CLIENT_IP_MODE=dhcp]
  --static, --client-static Force STB clients to use static IP configuration
  --no-stream             Do not auto-start streaming immediately after setup
  -h, --help              Show this help message

Notes:
  - If you only want to stream directly on WAN_IF with NO bridges/topology at all:
    sudo ./scripts/start_wan_server.sh run
    (or: sudo ./scripts/start_server.sh --direct run)
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

    require_cmd ip
    require_cmd ffmpeg
    require_cmd python3

    SERVER_ONLY="${SERVER_ONLY:-0}"
    CLIENT_IP_MODE="${CLIENT_IP_MODE:-dhcp}"
    local wan_only=0
    local auto_stream=1

    while (( $# > 0 )); do
        case "$1" in
            --virtual|-v|--no-dut)     IS_VIRTUAL=1; shift ;;
            --physical|-p)             IS_VIRTUAL=0; shift ;;
            --wan-only|-w)             wan_only=1; SERVER_ONLY=1; shift ;;
            --server-only|-s)          SERVER_ONLY=1; shift ;;
            -n|--clients)              CLIENT_COUNT="$2"; shift 2 ;;
            --dhcp|--client-dhcp)      CLIENT_IP_MODE="dhcp"; shift ;;
            --static|--client-static)  CLIENT_IP_MODE="static"; shift ;;
            --no-stream)               auto_stream=0; shift ;;
            -h|--help)                 usage; exit 0 ;;
            *)                         shift ;;
        esac
    done

    # Pre-flight check: Media sample asset
    if [[ ! -f "${MEDIA_DIR}/${MEDIA_FILE}" ]]; then
        log_warn "Test asset '${MEDIA_DIR}/${MEDIA_FILE}' missing. Generating sample 1080p stream..."
        "${SCRIPT_DIR}/generate_media.sh"
    fi

    # Physical interface safety checks
    if (( IS_VIRTUAL == 0 )); then
        assert_safe_test_if "${WAN_IF}"
        if (( wan_only == 0 )); then
            assert_safe_test_if "${LAN_IF}"
            [[ "${WAN_IF}" != "${LAN_IF}" ]] || die "WAN_IF and LAN_IF must differ."
        fi
    fi

    SETUP_ACTIVE=1
    trap 'rollback_setup $? ${LINENO}' ERR

    printf '==============================================================================\n'
    printf '        REAL IPTV MULTICAST LAB - SETUP (VIRTUAL: %d, WAN-ONLY: %d)          \n' "${IS_VIRTUAL}" "${wan_only}"
    printf '==============================================================================\n'

    log_info "Creating L2 test bridge: ${WAN_BRIDGE}..."
    bridge_create "${WAN_BRIDGE}"
    if (( wan_only == 0 )); then
        log_info "Creating L2 test bridge: ${LAN_BRIDGE}..."
        bridge_create "${LAN_BRIDGE}"
    fi

    if (( IS_VIRTUAL == 0 )); then
        log_info "Attaching physical interface ${WAN_IF} -> ${WAN_BRIDGE}..."
        attach_physical_to_bridge "${WAN_IF}" "${WAN_BRIDGE}"
        if (( wan_only == 0 )); then
            log_info "Attaching physical interface ${LAN_IF} -> ${LAN_BRIDGE}..."
            attach_physical_to_bridge "${LAN_IF}" "${LAN_BRIDGE}"
        fi
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
    printf '%s\n' "wan-gateway" > "${STATE_DIR}/hostname-${WAN_NS}.txt"
    printf '%s\n' "${WAN_NS_IP%%/*}" > "${STATE_DIR}/ip-${WAN_NS}.txt"
    printf '%s\n' "${WAN_NS_GW}" > "${STATE_DIR}/gw-${WAN_NS}.txt"

    if [[ "${ENABLE_WAN_DHCP:-0}" == "1" ]]; then
        wan_dhcp_server start
    fi

    log_info "Creating media server namespace: ${SERVER_NAME} (${SERVER_IP})..."
    attach_netns_to_bridge "${SERVER_NAME}" "${WAN_BRIDGE}" veth-mserv vpeer-mserv "${SERVER_IP}" "${SERVER_GW}" "mcast-server" "02:54:00:10:00:02"

    if (( SERVER_ONLY == 0 && wan_only == 0 )); then
        local count="${CLIENT_COUNT:-5}"
        log_info "Instantiating ${count} STB client namespaces (${CLIENT_IP_MODE} mode)..."
        local i
        for (( i=1; i<=count; i++ )); do
            local c_name c_host c_mac c_ip c_gw
            c_name="$(get_client_name "${i}")"
            c_host="$(get_client_hostname "${i}")"
            c_mac="$(get_client_mac "${i}")"

            if [[ "${CLIENT_IP_MODE}" == "dhcp" ]]; then
                c_ip=""
                c_gw=""
            else
                c_ip="$(get_client_ip "${i}")"
                c_gw="${CLIENT1_GW:-10.20.0.1}"
            fi

            log_info "  [Client ${i}/${count}] Creating ${c_name} (Host: '${c_host}', MAC: '${c_mac}')..."
            attach_netns_to_bridge "${c_name}" "${LAN_BRIDGE}" "veth-mc${i}" "vpeer-mc${i}" "${c_ip}" "${c_gw}" "${c_host}" "${c_mac}"
            force_netns_igmp_version "${c_name}" "${FORCE_IGMP_VERSION}"
        done

        if [[ "${CLIENT_IP_MODE}" == "dhcp" ]]; then
            log_info "Requesting DHCP leases for all clients from DUT LAN via udhcpc..."
            "${SCRIPT_DIR}/client_dhcp.sh" daemon all || log_warn "DHCP lease request to DUT LAN timed out; clients will continue in background."
        fi
    else
        log_info "STB client namespaces skipped (server_only=${SERVER_ONLY}, wan_only=${wan_only})."
    fi

    if (( IS_VIRTUAL == 1 && wan_only == 0 )); then
        setup_virtual_dut
    fi

    if (( auto_stream == 1 )); then
        log_info "Auto-starting media server streaming on ${SERVER_NAME}..."
        "${SCRIPT_DIR}/start_server.sh" --netns start
    fi

    cat >"${STATE_DIR}/topology_state.env" <<EOF
IS_VIRTUAL='${IS_VIRTUAL}'
SERVER_ONLY='${SERVER_ONLY}'
WAN_ONLY='${wan_only}'
CLIENT_IP_MODE='${CLIENT_IP_MODE}'
CLIENT_COUNT='${CLIENT_COUNT:-5}'
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
    log_info "Setup completed successfully (virtual=${IS_VIRTUAL}, wan_only=${wan_only}, server_only=${SERVER_ONLY})."
}

main "$@"
