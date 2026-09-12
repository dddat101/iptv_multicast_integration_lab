#!/usr/bin/env bash
# ==============================================================================
# REAL IPTV MULTICAST TEST LAB - GUI STREAM VIEWER
# Configures host multicast routing and launches desktop VLC/FFplay on Ubuntu.
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
load_config

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
  -h, --help    Show this help message

Examples:
  ./scripts/view_stream_gui.sh lan
  ./scripts/view_stream_gui.sh wan

Suggested Next Steps:
  - Check lab state:       ./scripts/show_state.sh
  - Run scenario smoke:    sudo ./scripts/scenario.sh
USAGE
}

for arg in "$@"; do
    if [[ "${arg}" == "-h" || "${arg}" == "--help" ]]; then
        usage
        exit 0
    fi
done

TARGET="${1:-lan}" # 'lan' (through DUT) or 'wan' (direct from server)
HOST_IP=""
BRIDGE=""

case "${TARGET}" in
    lan)
        BRIDGE="${LAN_BRIDGE}"
        HOST_IP="10.20.0.99/24"
        ;;
    wan)
        BRIDGE="${WAN_BRIDGE}"
        HOST_IP="10.10.0.99/24"
        ;;
    -h|--help)
        usage
        exit 0
        ;;
    *)
        usage
        exit 1
        ;;
esac


cleanup_gui_route() {
    log_info "Cleaning up host temporary multicast route on ${BRIDGE}..."
    sudo ip route del 224.0.0.0/4 dev "${BRIDGE}" 2>/dev/null || true
    sudo ip addr del "${HOST_IP}" dev "${BRIDGE}" 2>/dev/null || true
}

trap cleanup_gui_route EXIT INT TERM

bridge_exists "${BRIDGE}" || die "Bridge '${BRIDGE}' not found. Run 'sudo ./scripts/setup.sh --physical' first."

log_info "Configuring host multicast routing on ${BRIDGE} (${HOST_IP})..."
sudo ip addr add "${HOST_IP}" dev "${BRIDGE}" 2>/dev/null || true
sudo ip route replace 224.0.0.0/4 dev "${BRIDGE}"

# Check player
PLAYER=""
if command -v vlc >/dev/null 2>&1; then
    PLAYER="vlc"
elif command -v ffplay >/dev/null 2>&1; then
    PLAYER="ffplay"
else
    die "Neither 'vlc' nor 'ffplay' is installed on Ubuntu host."
fi

log_info "Launching ${PLAYER} GUI for udp://@${MCAST_GROUP}:${MCAST_PORT}..."
printf 'Press Ctrl+C or close the player window to stop and clean up routes.\n'

if [[ "${PLAYER}" == "vlc" ]]; then
    vlc "udp://@${MCAST_GROUP}:${MCAST_PORT}"
else
    ffplay -i "udp://${MCAST_GROUP}:${MCAST_PORT}"
fi
