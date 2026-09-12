#!/usr/bin/env bash
# ==============================================================================
# REAL IPTV MULTICAST TEST LAB - PACKET CAPTURE MANAGER
# Standard daemon lifecycle (start, stop, status) with tcpdump/tshark support
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
load_config

readonly PID_FILE="${STATE_DIR}/capture.pid"
readonly META_FILE="${STATE_DIR}/latest_capture.txt"

usage() {
    cat <<'USAGE'
Description:
  Manages background packet capture (tcpdump / tshark) on LAN or WAN bridges/interfaces.
  Captures IGMP signaling, leave latency, and multicast MPEG-TS packet streams to PCAP files.

Usage:
  sudo ./scripts/capture.sh start [lan|wan|all] [bpf_filter]
  sudo ./scripts/capture.sh stop
  ./scripts/capture.sh status
  ./scripts/capture.sh clean
  ./scripts/capture.sh -h | --help

Commands:
  start [target] [filter]  Start background packet capture on target interface (lan, wan, or all)
                           Default target: lan. Default filter: "igmp or (udp and port 5000)"
  stop                     Stop active background packet capture
  status                   Display capture status, active PID, and output PCAP file details
  clean                    Stop active capture and purge all capture files in captures/
  -h, --help               Show this help message

Examples:
  sudo ./scripts/capture.sh start lan
  sudo ./scripts/capture.sh start wan "igmp"
  sudo ./scripts/capture.sh status
  sudo ./scripts/capture.sh stop
  ./scripts/capture.sh clean

Suggested Next Steps:
  - Run automated analysis: ./scripts/verify_capture.sh full
  - Inspect running status: ./scripts/capture.sh status
USAGE
}


select_capture_iface() {
    local target="$1"
    case "${target}" in
        lan)
            if bridge_exists "${LAN_BRIDGE}"; then
                printf '%s\n' "${LAN_BRIDGE}"
            elif [[ -n "${LAN_IF:-}" ]] && iface_exists_root "${LAN_IF}"; then
                printf '%s\n' "${LAN_IF}"
            else
                die "No LAN bridge (${LAN_BRIDGE}) or physical NIC (${LAN_IF:-}) found."
            fi
            ;;
        wan)
            if bridge_exists "${WAN_BRIDGE}"; then
                printf '%s\n' "${WAN_BRIDGE}"
            elif [[ -n "${WAN_IF:-}" ]] && iface_exists_root "${WAN_IF}"; then
                printf '%s\n' "${WAN_IF}"
            else
                die "No WAN bridge (${WAN_BRIDGE}) or physical NIC (${WAN_IF:-}) found."
            fi
            ;;
        all|any)
            if bridge_exists "${LAN_BRIDGE}"; then
                printf '%s\n' "${LAN_BRIDGE}"
            else
                printf 'any\n'
            fi
            ;;
        *)
            die "Unknown capture target '${target}'. Choose: lan, wan, all."
            ;;
    esac
}

start_capture() {
    local target="${1:-lan}"
    local custom_filter="${2:-${CAPTURE_FILTER}}"
    local iface
    local timestamp
    local pcap_file
    local tool="tcpdump"

    require_root
    ensure_runtime_dirs

    if is_pidfile_running "${PID_FILE}"; then
        log_warn "Capture already running (PID $(cat "${PID_FILE}")). Stop it first."
        return 0
    fi

    iface="$(select_capture_iface "${target}")"
    timestamp="$(date '+%Y%m%d_%H%M%S')"
    pcap_file="${CAPTURE_DIR}/${target}_${timestamp}.pcap"

    if command -v tcpdump >/dev/null 2>&1; then
        tool="tcpdump"
        log_info "Starting packet capture on ${iface} with tcpdump (filter: ${custom_filter})..."
        nohup tcpdump -i "${iface}" -s 0 -U -nn -e -w "${pcap_file}" "${custom_filter}" \
            >"${LOG_DIR}/capture.log" 2>&1 &
    elif command -v tshark >/dev/null 2>&1; then
        tool="tshark"
        log_info "Starting packet capture on ${iface} with tshark (filter: ${custom_filter})..."
        nohup tshark -i "${iface}" -f "${custom_filter}" -w "${pcap_file}" \
            >"${LOG_DIR}/capture.log" 2>&1 &
    else
        die "Neither tcpdump nor tshark is installed."
    fi

    local pid=$!
    printf '%s\n' "${pid}" > "${PID_FILE}"
    printf '%s\n' "${pcap_file}" > "${META_FILE}"
    chmod 0666 "${PID_FILE}" "${META_FILE}" 2>/dev/null || true
    sleep 0.5

    if ! kill -0 "${pid}" 2>/dev/null; then
        log_error "Capture failed to start on ${iface}."
        cat "${LOG_DIR}/capture.log" >&2 || true
        rm -f "${PID_FILE}"
        return 1
    fi

    log_info "Capture started on ${iface} (${tool}): ${pcap_file}"
}

stop_capture() {
    require_root

    if is_pidfile_running "${PID_FILE}"; then
        local pid
        pid="$(cat "${PID_FILE}")"
        log_info "Stopping packet capture [PID ${pid}]..."
        stop_pidfile "${PID_FILE}"
        if [[ -f "${META_FILE}" ]]; then
            local file
            file="$(cat "${META_FILE}")"
            log_info "Capture saved to: ${file}"
            chmod 0666 "${file}" 2>/dev/null || true
        fi
    else
        rm -f "${PID_FILE}" 2>/dev/null || true
        log_info "No active capture process found."
    fi
}

show_status() {
    printf '== Capture Status ==\n'
    if is_pidfile_running "${PID_FILE}"; then
        local pid file
        pid="$(cat "${PID_FILE}")"
        file="$(cat "${META_FILE}" 2>/dev/null || printf '<unknown>')"
        printf 'Status:  RUNNING (PID %s)\n' "${pid}"
        printf 'File:    %s\n' "${file}"
        if [[ -f "${file}" ]]; then
            printf 'Size:    %s bytes\n' "$(stat -c %s "${file}" 2>/dev/null || echo '?')"
        fi
    else
        printf 'Status:  STOPPED\n'
        if [[ -f "${META_FILE}" ]]; then
            printf 'Last:    %s\n' "$(cat "${META_FILE}")"
        fi
    fi
}

main() {
    for arg in "$@"; do
        if [[ "${arg}" == "-h" || "${arg}" == "--help" ]]; then
            usage
            exit 0
        fi
    done

    load_config
    local action="${1:-status}"

    case "${action}" in
        start)
            shift
            start_capture "$@"
            ;;
        stop)
            stop_capture
            ;;
        status)
            show_status
            ;;
        clean)
            if is_pidfile_running "${PID_FILE}"; then
                stop_capture
            fi
            clean_captures
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage
            exit 2
            ;;
    esac
}

main "$@"
