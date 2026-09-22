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
  validates namespaces, captures LAN packets, launches FFmpeg media stream,
  triggers IGMPv2 Joins from STB clients, verifies multi-client reception, executes
  Leaves (Fast Leave testing), and performs automated PCAP compliance verification.

Usage:
  sudo ./scripts/scenario.sh [phase]
  ./scripts/scenario.sh -h | --help

Phases:
  all         (Default) Run complete end-to-end multi-phase scenario & verification
  discovery   Phase 1: Validate namespaces & STB client addressing/DHCP
  traffic     Phase 2: Start streamer & multi-client IGMP joins
  leave       Phase 3: Client Fast Leave signaling & teardown
  verify      Phase 4: Run PCAP compliance verification engine

Options:
  -h, --help  Show this help message and exit

Examples:
  sudo ./scripts/scenario.sh
  sudo ./scripts/scenario.sh all
  sudo ./scripts/scenario.sh discovery
  sudo ./scripts/scenario.sh traffic
  ./scripts/scenario.sh verify

Suggested Next Steps:
  - Run benchmark suite:    sudo ./scripts/benchmark_suite.sh all
  - Inspect PCAP capture:   ./scripts/verify_compliance.sh
  - Teardown lab:           sudo ./scripts/cleanup.sh
USAGE
}

run_phase_discovery() {
    log_step "[PHASE 1] Validating environment & STB client addressing..."
    netns_exists "${SERVER_NAME}"  || die "Server '${SERVER_NAME}' not running. Run sudo ./scripts/setup.sh first."
    netns_exists "${CLIENT1_NAME}" || die "Client 1 '${CLIENT1_NAME}' not running. Run sudo ./scripts/setup.sh first."
    netns_exists "${CLIENT2_NAME}" || die "Client 2 '${CLIENT2_NAME}' not running. Run sudo ./scripts/setup.sh first."

    if [[ ! -f "${MEDIA_DIR}/${MEDIA_FILE}" ]]; then
        log_warn "Media file missing. Auto-generating 1080p sample with scripts/generate_media.sh..."
        "${SCRIPT_DIR}/generate_media.sh"
    fi

    local c1_ip c2_ip
    c1_ip="$(ip -n "${CLIENT1_NAME}" -4 -o addr show dev eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || echo '<no-ip>')"
    c2_ip="$(ip -n "${CLIENT2_NAME}" -4 -o addr show dev eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || echo '<no-ip>')"
    log_info "STB Client 1 (${CLIENT1_NAME}): IP ${c1_ip}"
    log_info "STB Client 2 (${CLIENT2_NAME}): IP ${c2_ip}"
}

run_phase_traffic() {
    log_step "[PHASE 2] Starting media stream & multi-client joins..."
    log_info "Starting background FFmpeg MPEG-TS stream on ${SERVER_NAME}..."
    "${SCRIPT_DIR}/start_server.sh" start

    # Deterministic wait: wait for media server process
    sleep 1

    local c1_ip
    c1_ip="$(ip -n "${CLIENT1_NAME}" -4 -o addr show dev eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || echo '<no-ip>')"
    log_info "Starting VLC in ${CLIENT1_NAME} (IP: ${c1_ip}) (sends IGMPv2 Join)..."
    "${SCRIPT_DIR}/start_client.sh" 1 start
    sleep 3

    local c2_ip
    c2_ip="$(ip -n "${CLIENT2_NAME}" -4 -o addr show dev eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || echo '<no-ip>')"
    log_info "Starting VLC in ${CLIENT2_NAME} (IP: ${c2_ip}) (Multi-client join)..."
    "${SCRIPT_DIR}/start_client.sh" 2 start
    sleep 3
}

run_phase_leave() {
    log_step "[PHASE 3] Executing client leaves (Fast Leave / Zapping)..."
    log_info "Stopping VLC in ${CLIENT1_NAME} (IGMP Leave)..."
    "${SCRIPT_DIR}/start_client.sh" 1 stop
    sleep 2

    log_info "Stopping VLC in ${CLIENT2_NAME} (IGMP Leave)..."
    "${SCRIPT_DIR}/start_client.sh" 2 stop
    sleep 1

    log_info "Stopping media streamer..."
    "${SCRIPT_DIR}/start_server.sh" stop
}

run_phase_verify() {
    log_step "[PHASE 4] Running automated PCAP compliance verification..."
    if [[ -x "${SCRIPT_DIR}/verify_compliance.sh" ]]; then
        "${SCRIPT_DIR}/verify_compliance.sh"
    elif [[ -x "${SCRIPT_DIR}/verify_capture.sh" ]]; then
        "${SCRIPT_DIR}/verify_capture.sh" full
    fi
}

main() {
    for arg in "$@"; do
        if [[ "${arg}" == "-h" || "${arg}" == "--help" ]]; then
            usage
            exit 0
        fi
    done

    local phase="${1:-all}"

    if [[ "${phase}" == "verify" ]]; then
        load_config
        run_phase_verify
        return 0
    fi

    require_root
    load_config

    trap cleanup_scenario EXIT INT TERM

    print_header "REAL IPTV MULTICAST LAB - AUTOMATED SCENARIO [${phase^^}]"

    case "${phase}" in
        all)
            # Phase 0: Validate environment
            run_phase_discovery

            # Phase 1: Start LAN packet capture
            log_info "Starting packet capture on LAN bridge (${LAN_BRIDGE})..."
            "${SCRIPT_DIR}/capture.sh" start lan
            sleep 1

            # Phase 2: Traffic & Joins
            run_phase_traffic

            # Phase 3: Leaves
            run_phase_leave

            # Stop capture before verification
            log_info "Stopping packet capture..."
            "${SCRIPT_DIR}/capture.sh" stop

            # Phase 4: Verification
            trap - EXIT INT TERM
            run_phase_verify
            ;;
        discovery)
            run_phase_discovery
            trap - EXIT INT TERM
            ;;
        traffic)
            run_phase_discovery
            run_phase_traffic
            trap - EXIT INT TERM
            ;;
        leave)
            run_phase_leave
            trap - EXIT INT TERM
            ;;
        *)
            log_error "Unknown scenario phase: ${phase}"
            usage
            exit 1
            ;;
    esac
}

main "$@"
