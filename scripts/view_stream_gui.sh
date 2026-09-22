#!/usr/bin/env bash
# ==============================================================================
# REAL IPTV MULTICAST TEST LAB - GUI STREAM VIEWER
# Configures host multicast routing and launches desktop VLC/FFplay on Ubuntu.
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
    cat <<'USAGE'
Description:
  Configures host multicast routing and launches desktop VLC or FFplay GUI
  to view real-time video streaming on LAN (through DUT) or WAN (direct from server).

Usage:
  ./scripts/view_stream_gui.sh [lan|wan]
  ./scripts/view_stream_gui.sh -h | --help

Options / Arguments:
  lan           Watch stream forwarded by DUT router on LAN side [Default]
  wan           Watch stream directly from Media Server on WAN side
  -h, --help    Show this help message and exit

Examples:
  ./scripts/view_stream_gui.sh lan
  ./scripts/view_stream_gui.sh wan

Suggested Next Steps:
  - Check lab state:       ./scripts/show_state.sh
  - Run scenario smoke:    sudo ./scripts/scenario.sh
USAGE
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
        local saved_proto saved_mcast
        saved_proto="$(grep '^IP_VERSION=' "${STATE_DIR}/topology_state.env" 2>/dev/null | cut -d= -f2 | tr -d "'\"" || true)"
        saved_mcast="$(grep '^MCAST_GROUP=' "${STATE_DIR}/topology_state.env" 2>/dev/null | cut -d= -f2 | tr -d "'\"" || true)"
        [[ -n "${saved_proto}" ]] && IP_VERSION="${saved_proto}"
        [[ -n "${saved_mcast}" ]] && MCAST_GROUP="${saved_mcast}"
    fi

    local target="${1:-lan}"
    local host_ip=""
    local bridge=""

    case "${target}" in
        lan)
            bridge="${LAN_BRIDGE}"
            if [[ "${IP_VERSION:-4}" == "6" || "${MCAST_GROUP}" =~ : ]]; then
                host_ip="fd00:10:20::99/64"
            else
                host_ip="10.20.0.99/24"
            fi
            ;;
        wan)
            bridge="${WAN_BRIDGE}"
            if [[ "${IP_VERSION:-4}" == "6" || "${MCAST_GROUP}" =~ : ]]; then
                host_ip="fd00:10:10::99/64"
            else
                host_ip="10.10.0.99/24"
            fi
            ;;
        *)
            usage
            exit 1
            ;;
    esac

    cleanup_gui_route() {
        log_info "Cleaning up host temporary multicast route on ${bridge}..."
        if [[ "${host_ip}" =~ : ]]; then
            sudo ip -6 route del ff00::/8 dev "${bridge}" 2>/dev/null || true
        else
            sudo ip route del 224.0.0.0/4 dev "${bridge}" 2>/dev/null || true
        fi
        sudo ip addr del "${host_ip}" dev "${bridge}" 2>/dev/null || true
    }

    trap cleanup_gui_route EXIT INT TERM

    bridge_exists "${bridge}" || die "Bridge '${bridge}' not found. Run 'sudo ./scripts/setup.sh' first."

    log_info "Configuring host multicast routing on ${bridge} (${host_ip})..."
    if [[ "${host_ip}" =~ : ]]; then
        sudo sysctl -q -w "net.ipv6.conf.${bridge}.disable_ipv6=0" 2>/dev/null || true
        sudo sysctl -q -w "net.ipv6.conf.${bridge}.accept_dad=0" 2>/dev/null || true
        sudo ip addr add "${host_ip}" dev "${bridge}" nodad 2>/dev/null || true
        sudo ip -6 route replace ff00::/8 dev "${bridge}"
    else
        sudo ip addr add "${host_ip}" dev "${bridge}" 2>/dev/null || true
        sudo ip route replace 224.0.0.0/4 dev "${bridge}"
    fi

    # Check player
    local player=""
    if command -v vlc >/dev/null 2>&1; then
        player="vlc"
    elif command -v ffplay >/dev/null 2>&1; then
        player="ffplay"
    else
        die "Neither 'vlc' nor 'ffplay' is installed on Ubuntu host."
    fi

    local url_target
    if [[ "${MCAST_GROUP}" =~ : ]]; then
        url_target="[${MCAST_GROUP}]:${MCAST_PORT}"
    else
        url_target="${MCAST_GROUP}:${MCAST_PORT}"
    fi

    log_info "Launching ${player} GUI for udp://@${url_target}..."
    printf 'Press Ctrl+C or close the player window to stop and clean up routes.\n'

    if [[ "${player}" == "vlc" ]]; then
        vlc "udp://@${url_target}"
    else
        ffplay -i "udp://${url_target}"
    fi
}

main "$@"
