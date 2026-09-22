#!/usr/bin/env bash
# ==============================================================================
# REAL IPTV MULTICAST TEST LAB - STANDALONE WAN MEDIA SERVER
# Streams IPTV multicast directly on WAN_IF without requiring full topology
# or test bridges. Ideal for testing with router WAN port.
# ==============================================================================

set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat <<'USAGE'
Description:
  Standalone WAN IPTV Media Server that transmits UDP MPEG-TS video directly
  out of the physical WAN_IF or specified interface without requiring virtual
  bridges or network namespaces.

Usage:
  sudo ./scripts/start_wan_server.sh [options] [command]
  ./scripts/start_wan_server.sh -h | --help

Commands:
  run             Run streaming interactively in foreground [Default if TTY]
  start           Run streaming in background daemon mode
  stop            Stop streaming daemon and release interfaces
  status          Show status of media streaming daemon

Options:
  -i, --interface <iface> Specify physical interface for streaming (e.g. eno1, enxd46e...)
  -g, --group <ip>        Override multicast destination IP (default: 239.10.10.10)
  -p, --port <port>       Override UDP destination port (default: 5000)
  -h, --help              Show this help message and exit

Examples:
  sudo ./scripts/start_wan_server.sh run
  sudo ./scripts/start_wan_server.sh -i eno1 start
  ./scripts/start_wan_server.sh status
  sudo ./scripts/start_wan_server.sh stop

Suggested Next Steps:
  - Check stream status:   ./scripts/start_wan_server.sh status
  - Verify stream on LAN:  ./scripts/view_stream_gui.sh lan
  - Inspect running state: ./scripts/show_state.sh
USAGE
}

for arg in "$@"; do
    if [[ "${arg}" == "-h" || "${arg}" == "--help" ]]; then
        usage
        exit 0
    fi
done

exec "${SCRIPT_DIR}/start_server.sh" --direct "$@"
