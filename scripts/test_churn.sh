#!/usr/bin/env bash
# ==============================================================================
# RAPID JOIN/LEAVE CHURN BENCHMARK
# Evaluates control-plane stability under rapid Join/Leave churn cycles
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
    cat <<'USAGE'
Description:
  Evaluates router/DUT control-plane stability under rapid IGMPv2 Join/Leave
  churn cycles from an emulated STB client or LAN interface.

Usage:
  sudo ./scripts/test_churn.sh [options] [multicast_group] [interval_ms] [cycles]

Arguments / Options:
  multicast_group   Multicast group IPv4 address (default: MCAST_GROUP or 239.10.10.10)
  interval_ms       Delay between Join and Leave in milliseconds (default: 100)
  cycles            Number of churn cycles to execute (default: 30)
  -h, --help        Show this help message

Examples:
  sudo ./scripts/test_churn.sh
  sudo ./scripts/test_churn.sh 239.10.10.10 50 50

Suggested Next Steps:
  - Inspect DUT state:      ./scripts/dut_collector.sh collect
  - Run scale benchmark:    sudo ./scripts/test_scale.sh
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

    local group="${1:-${MCAST_GROUP:-239.10.10.10}}"
    local interval="${2:-${CHURN_INTERVAL_MS:-100}}"
    local cycles="${3:-${CHURN_CYCLES:-30}}"


    printf '==============================================================================\n'
    printf '   RAPID JOIN/LEAVE CHURN BENCHMARK (%d CYCLES @ %d MS)                      \n' "${cycles}" "${interval}"
    printf '==============================================================================\n'

    local if_ip=""

    if netns_exists "${CLIENT1_NAME:-ns-stb1}"; then
        if_ip="$(ip -n "${CLIENT1_NAME}" -4 -o addr show dev eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)"
        if [[ -z "${if_ip}" ]]; then
            if_ip="$(cat "${STATE_DIR}/ip-${CLIENT1_NAME}.txt" 2>/dev/null || true)"
        fi
        if [[ -n "${if_ip}" ]]; then
            log_info "Running rapid churn from namespace ${CLIENT1_NAME} (IP: ${if_ip})..."
            ip netns exec "${CLIENT1_NAME}" python3 "${SCRIPT_DIR}/../tools/igmp_client.py" \
                --interface-ip "${if_ip}" \
                --groups "${group}" \
                --interval-ms "${interval}" \
                --cycles "${cycles}"
            log_info "Churn Benchmark PASS: Executed ${cycles} cycles successfully."
            return 0
        fi
    fi

    local iface="${LAN_IF:-${LAN_BRIDGE}}"
    if_ip="$(ip -4 -o addr show dev "${iface}" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)"
    [[ -n "${if_ip}" ]] || die "Unable to determine IPv4 address for LAN interface ${iface}."

    log_info "Running rapid churn on host interface ${iface} (IP: ${if_ip})..."
    python3 "${SCRIPT_DIR}/../tools/igmp_client.py" \
        --interface-ip "${if_ip}" \
        --groups "${group}" \
        --interval-ms "${interval}" \
        --cycles "${cycles}"

    log_info "Churn Benchmark PASS: Executed ${cycles} cycles successfully."
}

main "$@"
