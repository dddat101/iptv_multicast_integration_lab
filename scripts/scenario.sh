#!/usr/bin/env bash
# ==============================================================================
# REAL IPTV MULTICAST TEST LAB - AUTOMATED TEST SCENARIO
# Multi-phase end-to-end qualification: Video Streaming, IGMP Join, Multi-Client, Leave
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

cleanup_scenario() {
    log_info "Tearing down scenario background jobs..."
    "${SCRIPT_DIR}/start_client.sh" 1 stop >/dev/null 2>&1 || true
    "${SCRIPT_DIR}/start_client.sh" 2 stop >/dev/null 2>&1 || true
    "${SCRIPT_DIR}/start_server.sh" stop >/dev/null 2>&1 || true
    "${SCRIPT_DIR}/capture.sh" stop >/dev/null 2>&1 || true
}

usage() {
    cat <<'USAGE'
Description:
  Executes an automated multi-phase end-to-end IPTV multicast qualification scenario:
  Validates namespaces, starts LAN packet capture, launches FFmpeg media stream,
  triggers IGMPv2 Joins from STB clients, verifies multi-client reception, executes
  Leaves (Fast Leave testing), and performs automated PCAP verification.

Usage:
  sudo ./scripts/scenario.sh [options]

Options:
  -h, --help    Show this help message

Examples:
  sudo ./scripts/scenario.sh

Suggested Next Steps:
  - Inspect PCAP capture:   ./scripts/verify_capture.sh full
  - Run benchmark suite:    sudo ./scripts/benchmark_suite.sh all
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


    trap cleanup_scenario EXIT INT TERM

    printf '==============================================================================\n'
    printf '        REAL IPTV MULTICAST LAB - AUTOMATED SMOKE SCENARIO                     \n'
    printf '==============================================================================\n'

    # Phase 0: Validate environment
    log_info "Phase 0: Validating environment and namespaces..."
    netns_exists "${SERVER_NAME}"  || die "Server '${SERVER_NAME}' not running. Run sudo ./scripts/setup.sh first."
    netns_exists "${CLIENT1_NAME}" || die "Client 1 '${CLIENT1_NAME}' not running. Run sudo ./scripts/setup.sh first."
    netns_exists "${CLIENT2_NAME}" || die "Client 2 '${CLIENT2_NAME}' not running. Run sudo ./scripts/setup.sh first."

    if [[ ! -f "${MEDIA_DIR}/${MEDIA_FILE}" ]]; then
        log_warn "Media file missing. Auto-generating 1080p sample with scripts/generate_media.sh..."
        "${SCRIPT_DIR}/generate_media.sh"
    fi

    # Phase 1: Start packet capture on LAN side
    log_info "Phase 1: Starting packet capture on LAN bridge (${LAN_BRIDGE})..."
    "${SCRIPT_DIR}/capture.sh" start lan
    sleep 1

    # Phase 2: Start continuous MPEG-TS stream from Server
    log_info "Phase 2: Starting background FFmpeg MPEG-TS stream on ${SERVER_NAME}..."
    "${SCRIPT_DIR}/start_server.sh" start
    sleep 1

    # Phase 3: Client 1 joins the stream
    local c1_ip
    c1_ip="$(ip -n "${CLIENT1_NAME}" -4 -o addr show dev eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || echo '<no-ip>')"
    log_info "Phase 3: Starting VLC in ${CLIENT1_NAME} (IP: ${c1_ip}) (sends IGMPv2 Join)..."
    "${SCRIPT_DIR}/start_client.sh" 1 start
    sleep 4

    # Phase 4: Client 2 joins the stream (Multi-client verification)
    local c2_ip
    c2_ip="$(ip -n "${CLIENT2_NAME}" -4 -o addr show dev eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || echo '<no-ip>')"
    log_info "Phase 4: Starting VLC in ${CLIENT2_NAME} (IP: ${c2_ip}) (Multi-client join)..."
    "${SCRIPT_DIR}/start_client.sh" 2 start
    sleep 3

    # Phase 5: Client 1 leaves (Fast Leave / Zapping test)
    log_info "Phase 5: Stopping VLC in ${CLIENT1_NAME} (IGMP Leave)..."
    "${SCRIPT_DIR}/start_client.sh" 1 stop
    sleep 2

    # Phase 6: Client 2 leaves
    log_info "Phase 6: Stopping VLC in ${CLIENT2_NAME} (IGMP Leave)..."
    "${SCRIPT_DIR}/start_client.sh" 2 stop
    sleep 1

    # Phase 7: Stop server and packet capture
    log_info "Phase 7: Stopping media server and packet capture..."
    "${SCRIPT_DIR}/start_server.sh" stop
    "${SCRIPT_DIR}/capture.sh" stop
    sleep 1

    # Phase 8: Automated PCAP Verification
    log_info "Phase 8: Running automated PCAP verification..."
    if "${SCRIPT_DIR}/verify_capture.sh" full; then
        log_info "SCENARIO RESULT: PASS"
        trap - EXIT
        return 0
    else
        log_error "SCENARIO RESULT: FAIL"
        trap - EXIT
        return 1
    fi
}

main "$@"
