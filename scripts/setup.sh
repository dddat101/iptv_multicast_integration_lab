#!/usr/bin/env bash
# ==============================================================================
# REAL IPTV MULTICAST TEST LAB - TOPOLOGY SETUP
# Supports Physical DUT mode, Virtual Simulation mode (--virtual),
# WAN-only mode (--wan-only), and Server-only mode (--server-only).
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

SETUP_ACTIVE=0

rollback_setup() {
    local exit_code="${1:-1}"
    local line_no="${2:-unknown}"

    if (( SETUP_ACTIVE == 1 )); then
        SETUP_ACTIVE=0
        log_error "Setup failed at line ${line_no} (exit code: ${exit_code}). Initiating automatic cleanup..."
        "${SCRIPT_DIR}/cleanup.sh" || true
    fi
    exit "${exit_code}"
}

usage() {
    cat <<'USAGE'
Description:
  Initializes and configures the IPTV multicast testbed topology across Linux
  network namespaces, L2 test bridges, veth pairs, and physical test adapters.
  Supports Physical DUT, Single-PC Dual-NIC, Virtual Simulation, and WAN-Only modes.

Usage:
  sudo ./scripts/setup.sh [options]
  ./scripts/setup.sh -h | --help

Options:
  -p, --physical, --single Run in Physical DUT / Single-PC Dual-NIC mode [Default]
  -v, --virtual, --no-dut  Run in Virtual Simulation mode (bridges namespaces via ns-dut)
  -w, --wan-only           Deploy WAN side only (WAN bridge, WAN DHCP & Server; skips LAN)
  -s, --server-only        Deploy Media Server only (skip STB client namespaces)
  -4, --ipv4, --ip4        Deploy topology using IPv4 protocol (IGMPv2) [Default]
  -6, --ipv6, --ip6        Deploy topology using IPv6 protocol (MLDv2)
  --dual, --dual-stack, -ds Deploy topology in Dual-Stack mode (concurrent IPv4 + IPv6)
  -n, --clients <count>    Number of STB client namespaces to emulate (default: 5)
  --dhcp, --client-dhcp    Have STB clients obtain dynamic IP from DUT LAN DHCP
  --static, --client-static Force STB clients to use static IP configuration
  --no-stream              Do not auto-start streaming immediately after setup
  -h, --help               Show this help message and exit

Examples:
  sudo ./scripts/setup.sh --virtual
  sudo ./scripts/setup.sh --single
  sudo ./scripts/setup.sh -s -w -4
  sudo ./scripts/setup.sh -s -w -6
  sudo ./scripts/setup.sh -s -w --dual
  sudo ./scripts/setup.sh --virtual --dual
  sudo ./scripts/setup.sh --physical --dhcp --clients 5
  sudo ./scripts/setup.sh --wan-only -6

Suggested Next Steps:
  - Inspect running state:  ./scripts/show_state.sh
  - Run automated scenario: sudo ./scripts/scenario.sh
  - Teardown lab:           sudo ./scripts/cleanup.sh
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
    IP_VERSION="${IP_VERSION:-4}"
    local wan_only=0
    local auto_stream=1

    while (( $# > 0 )); do
        case "$1" in
            --virtual|-v|--no-dut)     IS_VIRTUAL=1; shift ;;
            --physical|-p|--single)    IS_VIRTUAL=0; shift ;;
            --wan-only|-w)             wan_only=1; SERVER_ONLY=1; shift ;;
            --server-only|-s)          SERVER_ONLY=1; shift ;;
            -4|--ipv4|--ip4)           IP_VERSION="4"; shift ;;
            -6|--ipv6|--ip6)           IP_VERSION="6"; shift ;;
            --dual|--dual-stack|-ds|-2) IP_VERSION="dual"; shift ;;
            -n|--clients)
                shift
                [[ $# -gt 0 ]] || die "Missing value for --clients option"
                CLIENT_COUNT="$1"
                shift
                ;;
            --dhcp|--client-dhcp)      CLIENT_IP_MODE="dhcp"; shift ;;
            --static|--client-static)  CLIENT_IP_MODE="static"; shift ;;
            --no-stream)               auto_stream=0; shift ;;
            -h|--help)                 usage; exit 0 ;;
            *)                         usage; exit 2 ;;
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

    local current_mcast_group
    local current_wan_ns_ip
    local current_wan_ns_gw
    local current_server_ip
    local current_server_gw

    if [[ "${IP_VERSION}" == "dual" || "${IP_VERSION}" == "dual-stack" || "${IP_VERSION}" == "ds" ]]; then
        IP_VERSION="dual"
        current_mcast_group="${MCAST_GROUP:-239.10.10.10}"
        current_wan_ns_ip="${WAN_NS_IP:-10.10.0.254/24}"
        current_wan_ns_gw="${WAN_NS_GW:-10.10.0.1}"
        current_server_ip="${SERVER_IP:-10.10.0.2/24}"
        current_server_gw="${SERVER_GW:-10.10.0.1}"
    elif [[ "${IP_VERSION}" == "6" ]]; then
        current_mcast_group="${MCAST_GROUP6:-ff0e::10:10:10}"
        current_wan_ns_ip="${WAN_NS_IP6:-fd00:10:10::254/64}"
        current_wan_ns_gw="${WAN_NS_GW6:-fd00:10:10::1}"
        current_server_ip="${SERVER_IP6:-fd00:10:10::2/64}"
        current_server_gw="${SERVER_GW6:-fd00:10:10::1}"
    else
        current_mcast_group="${MCAST_GROUP:-239.10.10.10}"
        current_wan_ns_ip="${WAN_NS_IP:-10.10.0.254/24}"
        current_wan_ns_gw="${WAN_NS_GW:-10.10.0.1}"
        current_server_ip="${SERVER_IP:-10.10.0.2/24}"
        current_server_gw="${SERVER_GW:-10.10.0.1}"
    fi

    SETUP_ACTIVE=1
    trap 'rollback_setup "$?" "$LINENO"' ERR
    trap 'log_warn "Setup cancelled by signal! Rolling back..."; rollback_setup 130 "SIGINT/SIGTERM"' INT TERM

    local proto_label="IPv${IP_VERSION}"
    if [[ "${IP_VERSION}" == "dual" ]]; then
        proto_label="Dual-Stack (IPv4 + IPv6)"
    fi

    printf '==============================================================================\n'
    printf ' REAL IPTV MULTICAST LAB - SETUP (VIRTUAL: %d, WAN-ONLY: %d, %s)             \n' "${IS_VIRTUAL}" "${wan_only}" "${proto_label}"
    printf '==============================================================================\n'

    log_info "Creating L2 test bridge: ${WAN_BRIDGE} (${proto_label})..."
    bridge_create "${WAN_BRIDGE}" "${IP_VERSION}"
    if (( wan_only == 0 )); then
        log_info "Creating L2 test bridge: ${LAN_BRIDGE} (${proto_label})..."
        bridge_create "${LAN_BRIDGE}" "${IP_VERSION}"
    fi

    if (( IS_VIRTUAL == 0 )); then
        log_info "Attaching physical interface ${WAN_IF} -> ${WAN_BRIDGE} (${proto_label})..."
        attach_physical_to_bridge "${WAN_IF}" "${WAN_BRIDGE}" "${IP_VERSION}"
        if (( wan_only == 0 )); then
            log_info "Attaching physical interface ${LAN_IF} -> ${LAN_BRIDGE} (${proto_label})..."
            attach_physical_to_bridge "${LAN_IF}" "${LAN_BRIDGE}" "${IP_VERSION}"
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
    ip -n "${WAN_NS}" link set eth0 up

    if [[ "${IP_VERSION}" == "dual" ]]; then
        ip -n "${WAN_NS}" sysctl -q -w "net.ipv6.conf.all.disable_ipv6=0" 2>/dev/null || true
        ip -n "${WAN_NS}" sysctl -q -w "net.ipv6.conf.default.disable_ipv6=0" 2>/dev/null || true
        ip -n "${WAN_NS}" sysctl -q -w "net.ipv6.conf.eth0.disable_ipv6=0" 2>/dev/null || true
        ip -n "${WAN_NS}" sysctl -q -w "net.ipv6.conf.eth0.accept_dad=0" 2>/dev/null || true
        ip -n "${WAN_NS}" -4 addr flush dev eth0 2>/dev/null || true
        ip -n "${WAN_NS}" -6 addr flush dev eth0 scope global 2>/dev/null || true
        ip -n "${WAN_NS}" -6 addr add "fe80::254/64" dev eth0 nodad 2>/dev/null || true
        ip -n "${WAN_NS}" addr add "${WAN_NS_IP}" dev eth0
        ip -n "${WAN_NS}" -6 addr add "${WAN_NS_IP6}" dev eth0 nodad
        if [[ -n "${WAN_NS_GW:-}" && "${WAN_NS_GW}" != "${WAN_NS_IP%/*}" ]]; then
            ip -n "${WAN_NS}" route replace default via "${WAN_NS_GW}" dev eth0 2>/dev/null || true
        fi
        if [[ -n "${WAN_NS_GW6:-}" && "${WAN_NS_GW6}" != "${WAN_NS_IP6%/*}" ]]; then
            ip -n "${WAN_NS}" -6 route replace default via "${WAN_NS_GW6}" dev eth0 2>/dev/null || true
        fi
        ip -n "${WAN_NS}" route replace 224.0.0.0/4 dev eth0 2>/dev/null || true
        ip -n "${WAN_NS}" -6 route replace ff00::/8 dev eth0 2>/dev/null || true
        wait_for_ipv6_dad "${WAN_NS}" eth0 5
        printf '%s\n' "wan-gateway" > "${STATE_DIR}/hostname-${WAN_NS}.txt"
        printf '%s\n' "${WAN_NS_IP%%/*}" > "${STATE_DIR}/ip-${WAN_NS}.txt"
        printf '%s\n' "${WAN_NS_IP6%%/*}" > "${STATE_DIR}/ip6-${WAN_NS}.txt"
        printf '%s\n' "${WAN_NS_GW:-none}" > "${STATE_DIR}/gw-${WAN_NS}.txt"
        printf '%s\n' "${WAN_NS_GW6:-none}" > "${STATE_DIR}/gw6-${WAN_NS}.txt"
    elif [[ "${IP_VERSION}" == "6" ]]; then
        ip -n "${WAN_NS}" sysctl -q -w "net.ipv6.conf.all.disable_ipv6=0" 2>/dev/null || true
        ip -n "${WAN_NS}" sysctl -q -w "net.ipv6.conf.default.disable_ipv6=0" 2>/dev/null || true
        ip -n "${WAN_NS}" sysctl -q -w "net.ipv6.conf.eth0.disable_ipv6=0" 2>/dev/null || true
        ip -n "${WAN_NS}" sysctl -q -w "net.ipv6.conf.eth0.accept_dad=0" 2>/dev/null || true
        ip -n "${WAN_NS}" -6 addr flush dev eth0 scope global 2>/dev/null || true
        ip -n "${WAN_NS}" -6 addr add "fe80::254/64" dev eth0 nodad 2>/dev/null || true
        ip -n "${WAN_NS}" -6 addr add "${current_wan_ns_ip}" dev eth0 nodad
        if [[ -n "${current_wan_ns_gw:-}" && "${current_wan_ns_gw}" != "${current_wan_ns_ip%/*}" ]]; then
            ip -n "${WAN_NS}" -6 route replace default via "${current_wan_ns_gw}" dev eth0 2>/dev/null || true
        fi
        ip -n "${WAN_NS}" -6 route replace ff00::/8 dev eth0 2>/dev/null || true
        wait_for_ipv6_dad "${WAN_NS}" eth0 5
        printf '%s\n' "wan-gateway" > "${STATE_DIR}/hostname-${WAN_NS}.txt"
        printf '%s\n' "${current_wan_ns_ip%%/*}" > "${STATE_DIR}/ip6-${WAN_NS}.txt"
        printf '%s\n' "${current_wan_ns_gw:-none}" > "${STATE_DIR}/gw6-${WAN_NS}.txt"
    else
        ip -n "${WAN_NS}" -4 addr flush dev eth0 2>/dev/null || true
        ip -n "${WAN_NS}" addr add "${current_wan_ns_ip}" dev eth0
        if [[ -n "${current_wan_ns_gw:-}" && "${current_wan_ns_gw}" != "${current_wan_ns_ip%/*}" ]]; then
            ip -n "${WAN_NS}" route replace default via "${current_wan_ns_gw}" dev eth0 2>/dev/null || true
        fi
        ip -n "${WAN_NS}" route replace 224.0.0.0/4 dev eth0 2>/dev/null || true
        printf '%s\n' "wan-gateway" > "${STATE_DIR}/hostname-${WAN_NS}.txt"
        printf '%s\n' "${current_wan_ns_ip%%/*}" > "${STATE_DIR}/ip-${WAN_NS}.txt"
        printf '%s\n' "${current_wan_ns_gw:-none}" > "${STATE_DIR}/gw-${WAN_NS}.txt"
    fi

    if [[ "${ENABLE_WAN_DHCP:-0}" == "1" ]]; then
        wan_dhcp_server start "${IP_VERSION}"
    fi

    log_info "Creating media server namespace: ${SERVER_NAME}..."
    if [[ "${IP_VERSION}" == "dual" ]]; then
        attach_netns_to_bridge "${SERVER_NAME}" "${WAN_BRIDGE}" veth-mserv vpeer-mserv \
            "${SERVER_IP}" "${SERVER_GW}" "${SERVER_IP6}" "${SERVER_GW6}" \
            "mcast-server" "02:54:00:10:00:02" "dual"
    elif [[ "${IP_VERSION}" == "6" ]]; then
        attach_netns_to_bridge "${SERVER_NAME}" "${WAN_BRIDGE}" veth-mserv vpeer-mserv \
            "" "" "${SERVER_IP6}" "${SERVER_GW6}" \
            "mcast-server" "02:54:00:10:00:02" "6"
    else
        attach_netns_to_bridge "${SERVER_NAME}" "${WAN_BRIDGE}" veth-mserv vpeer-mserv \
            "${SERVER_IP}" "${SERVER_GW}" "" "" \
            "mcast-server" "02:54:00:10:00:02" "4"
    fi

    if (( SERVER_ONLY == 0 && wan_only == 0 )); then
        local count="${CLIENT_COUNT:-5}"
        log_info "Instantiating ${count} STB client namespaces (${CLIENT_IP_MODE} mode, ${proto_label})..."
        local i
        for (( i=1; i<=count; i++ )); do
            local c_name c_host c_mac c_v4_ip="" c_v4_gw="" c_v6_ip="" c_v6_gw=""
            c_name="$(get_client_name "${i}")"
            c_host="$(get_client_hostname "${i}")"
            c_mac="$(get_client_mac "${i}")"

            if [[ "${CLIENT_IP_MODE}" == "static" ]]; then
                if [[ "${IP_VERSION}" == "dual" ]]; then
                    c_v4_ip="$(get_client_ip "${i}")"
                    c_v4_gw="${CLIENT1_GW:-10.20.0.1}"
                    c_v6_ip="$(get_client_ip6 "${i}")"
                    c_v6_gw="${DUT_LAN_IP6:-fd00:10:20::1}"
                elif [[ "${IP_VERSION}" == "6" ]]; then
                    c_v6_ip="$(get_client_ip6 "${i}")"
                    c_v6_gw="${DUT_LAN_IP6:-fd00:10:20::1}"
                else
                    c_v4_ip="$(get_client_ip "${i}")"
                    c_v4_gw="${CLIENT1_GW:-10.20.0.1}"
                fi
            fi

            log_info "  [Client ${i}/${count}] Creating ${c_name} (Host: '${c_host}', MAC: '${c_mac}')..."
            attach_netns_to_bridge "${c_name}" "${LAN_BRIDGE}" "veth-mc${i}" "vpeer-mc${i}" \
                "${c_v4_ip}" "${c_v4_gw}" "${c_v6_ip}" "${c_v6_gw}" \
                "${c_host}" "${c_mac}" "${IP_VERSION}"

            if [[ "${IP_VERSION}" == "dual" ]]; then
                force_netns_igmp_version "${c_name}" "${FORCE_IGMP_VERSION:-2}"
                force_netns_mld_version "${c_name}" "${FORCE_MLD_VERSION:-2}"
            elif [[ "${IP_VERSION}" == "6" ]]; then
                force_netns_mld_version "${c_name}" "${FORCE_MLD_VERSION:-2}"
            else
                force_netns_igmp_version "${c_name}" "${FORCE_IGMP_VERSION:-2}"
            fi
        done

        if [[ "${CLIENT_IP_MODE}" == "dhcp" ]]; then
            if [[ "${IP_VERSION}" == "dual" ]]; then
                log_info "Requesting IPv4 DHCP leases and IPv6 SLAAC/DHCPv6 for all clients..."
                "${SCRIPT_DIR}/client_dhcp.sh" daemon all || log_warn "DHCP lease request to DUT LAN timed out; clients will continue in background."
                "${SCRIPT_DIR}/client_dhcp.sh" request-v6 all || log_warn "IPv6 SLAAC/DHCPv6 request to DUT LAN timed out."
            elif [[ "${IP_VERSION}" == "4" ]]; then
                log_info "Requesting DHCP leases for all clients from DUT LAN via udhcpc..."
                "${SCRIPT_DIR}/client_dhcp.sh" daemon all || log_warn "DHCP lease request to DUT LAN timed out; clients will continue in background."
            elif [[ "${IP_VERSION}" == "6" ]]; then
                log_info "Triggering IPv6 SLAAC/DHCPv6 for all clients from DUT LAN..."
                "${SCRIPT_DIR}/client_dhcp.sh" request-v6 all || log_warn "IPv6 SLAAC/DHCPv6 request to DUT LAN timed out."
            fi
        fi
    else
        log_info "STB client namespaces skipped (server_only=${SERVER_ONLY}, wan_only=${wan_only})."
    fi

    if (( IS_VIRTUAL == 1 && wan_only == 0 )); then
        setup_virtual_dut "${IP_VERSION}"
    fi

    cat >"${STATE_DIR}/topology_state.env" <<EOF
IP_VERSION='${IP_VERSION}'
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
MCAST_GROUP='${current_mcast_group}'
MCAST_GROUP6='${MCAST_GROUP6:-ff0e::10:10:10}'
MCAST_PORT='${MCAST_PORT}'
EOF

    if (( auto_stream == 1 )); then
        if [[ "${IP_VERSION}" == "dual" ]]; then
            log_info "Auto-starting media server streaming on ${SERVER_NAME} (Dual-Stack: ${MCAST_GROUP} & ${MCAST_GROUP6:-ff0e::10:10:10})..."
            "${SCRIPT_DIR}/start_server.sh" --netns --dual start
        elif [[ "${IP_VERSION}" == "6" ]]; then
            log_info "Auto-starting media server streaming on ${SERVER_NAME} (Group: ${current_mcast_group})..."
            "${SCRIPT_DIR}/start_server.sh" --netns -6 -g "${current_mcast_group}" start
        else
            log_info "Auto-starting media server streaming on ${SERVER_NAME} (Group: ${current_mcast_group})..."
            "${SCRIPT_DIR}/start_server.sh" --netns -4 -g "${current_mcast_group}" start
        fi
    fi

    SETUP_ACTIVE=0
    trap - ERR INT TERM
    log_info "Setup completed successfully (virtual=${IS_VIRTUAL}, wan_only=${wan_only}, server_only=${SERVER_ONLY}, ip_version=${IP_VERSION})."
}

main "$@"
