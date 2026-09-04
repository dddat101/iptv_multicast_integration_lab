#!/usr/bin/env bash
# ==============================================================================
# MULTI-GROUP MULTICAST PACKET LOSS BENCHMARK
# Measures quantitative packet loss across multiple multicast groups simultaneously
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

cleanup_loss_test() {
    stop_pidfile "${STATE_DIR}/loss_sender.pid" || true
}

main() {
    load_config

    local num_groups="${LOSS_TEST_GROUPS:-12}"
    local pkt_size="${LOSS_TEST_PACKET_SIZE:-1200}"
    local rate="${LOSS_TEST_RATE_PPS:-1200}"
    local duration="${LOSS_TEST_DURATION:-15}"
    local groups="239.100.1.1-${num_groups}"

    printf '==============================================================================\n'
    printf '   MULTI-GROUP MULTICAST LOSS MEASUREMENT BENCHMARK                           \n'
    printf '==============================================================================\n'
    printf 'Groups:         %s\n' "${groups}"
    printf 'Payload Size:   %d bytes\n' "${pkt_size}"
    printf 'Rate:           %d packets/sec (total across all groups)\n' "${rate}"
    printf 'Duration:       %d seconds\n' "${duration}"
    printf '------------------------------------------------------------------------------\n'

    trap cleanup_loss_test EXIT INT TERM

    # 1. Determine WAN sender IP & Interface
    local wan_ip=""
    local wan_iface=""

    if netns_exists "${SERVER_NAME:-ns-server}"; then
        wan_ip="$(ip -n "${SERVER_NAME}" -4 -o addr show dev eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)"
        if [[ -n "${wan_ip}" ]]; then
            log_info "Launching WAN sender in namespace ${SERVER_NAME} (IP: ${wan_ip})..."
            nohup ip netns exec "${SERVER_NAME}" python3 "${SCRIPT_DIR}/../tools/mcast_sender.py" \
                --interface-ip "${wan_ip}" \
                --groups "${groups}" \
                --payload-bytes "${pkt_size}" \
                --rate-pps "${rate}" \
                --duration-sec "$((duration + 5))" \
                >"${LOG_DIR}/loss_sender.log" 2>&1 &
            echo "$!" > "${STATE_DIR}/loss_sender.pid"
        fi
    fi

    if [[ -z "${wan_ip}" ]]; then
        wan_iface="${WAN_IF:-${WAN_BRIDGE}}"
        wan_ip="$(ip -4 -o addr show dev "${wan_iface}" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)"
        [[ -n "${wan_ip}" ]] || die "Unable to determine WAN IPv4 address for sender on ${wan_iface}."

        log_info "Launching WAN sender on host interface ${wan_iface} (IP: ${wan_ip})..."
        nohup python3 "${SCRIPT_DIR}/../tools/mcast_sender.py" \
            --interface-ip "${wan_ip}" \
            --groups "${groups}" \
            --payload-bytes "${pkt_size}" \
            --rate-pps "${rate}" \
            --duration-sec "$((duration + 5))" \
            >"${LOG_DIR}/loss_sender.log" 2>&1 &
        echo "$!" > "${STATE_DIR}/loss_sender.pid"
    fi

    sleep 1

    # 2. Launch LAN receiver
    local receiver_out=""
    local lan_ip=""

    if netns_exists "${CLIENT1_NAME:-ns-stb1}"; then
        lan_ip="$(ip -n "${CLIENT1_NAME}" -4 -o addr show dev eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)"
        if [[ -n "${lan_ip}" ]]; then
            log_info "Running LAN receiver in namespace ${CLIENT1_NAME} (IP: ${lan_ip})..."
            receiver_out="$(ip netns exec "${CLIENT1_NAME}" python3 "${SCRIPT_DIR}/../tools/mcast_receiver.py" \
                --interface-ip "${lan_ip}" \
                --groups "${groups}" \
                --duration-sec "${duration}" 2>&1 || true)"
        fi
    fi

    if [[ -z "${lan_ip}" ]]; then
        local lan_iface="${LAN_IF:-${LAN_BRIDGE}}"
        lan_ip="$(ip -4 -o addr show dev "${lan_iface}" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)"
        [[ -n "${lan_ip}" ]] || die "Unable to determine LAN IPv4 address for receiver on ${lan_iface}."

        log_info "Running LAN receiver on host interface ${lan_iface} (IP: ${lan_ip})..."
        receiver_out="$(python3 "${SCRIPT_DIR}/../tools/mcast_receiver.py" \
            --interface-ip "${lan_ip}" \
            --groups "${groups}" \
            --duration-sec "${duration}" 2>&1 || true)"
    fi

    printf '\n%s\n\n' "${receiver_out}"

    local received missing loss_ratio loss_pass
    received="$(printf '%s\n' "${receiver_out}" | awk -F= '$1 == "received_packets" {print $2; exit}' || echo "0")"
    missing="$(printf '%s\n' "${receiver_out}" | awk -F= '$1 == "missing_packets" {print $2; exit}' || echo "0")"
    loss_ratio="$(printf '%s\n' "${receiver_out}" | awk -F= '$1 == "loss_ratio" {print $2; exit}' || echo "N/A")"
    loss_pass="$(printf '%s\n' "${receiver_out}" | awk -F= '$1 == "loss_criteria_pass" {print $2; exit}' || echo "false")"

    printf '==============================================================================\n'
    printf '                 PACKET LOSS BENCHMARK SUMMARY                                 \n'
    printf '==============================================================================\n'
    printf 'Packets Received:       %s\n' "${received}"
    printf 'Packets Missing:        %s\n' "${missing}"
    printf 'Observed Loss Ratio:    %s\n' "${loss_ratio}"
    printf 'Loss Criteria (<=1e-9): %s\n' "$([[ "${loss_pass}" == "true" ]] && echo "PASS" || echo "FAIL / DEVIATION")"
    printf '==============================================================================\n'

    cleanup_loss_test
    trap - EXIT INT TERM
}

main "$@"
