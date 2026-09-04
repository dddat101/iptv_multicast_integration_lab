#!/usr/bin/env bash
# ==============================================================================
# REAL IPTV MULTICAST TEST LAB - STANDALONE WAN MEDIA SERVER
# Streams IPTV multicast directly on WAN_IF without requiring full topology
# or Docker test bridges. Ideal for testing with router WAN port.
# ==============================================================================

set -Eeuo pipefail
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${SCRIPT_DIR}/start_server.sh" --direct "$@"
