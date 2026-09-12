#!/usr/bin/env bash
# ==============================================================================
# FOREIGN LAN QUERIER INJECTION & BEHAVIOR BENCHMARK
# Injects foreign IGMP General Query on LAN to observe querier election & filtering
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
    cat <<'USAGE'
Description:
  Injects foreign IGMP General Queries on the LAN side to evaluate
  router querier election behavior, querier timeout, and query filtering.

Usage:
  ./scripts/test_foreign_querier.sh [options] [foreign_ip] [lan_interface]

Arguments / Options:
  foreign_ip        Source IP for foreign queries (default: FOREIGN_QUERIER_IP or 192.168.1.250)
  lan_interface     LAN interface or bridge (default: LAN_IF or LAN_BRIDGE)
  -h, --help        Show this help message

Examples:
  ./scripts/test_foreign_querier.sh
  ./scripts/test_foreign_querier.sh 192.168.1.254

Suggested Next Steps:
  - Inspect DUT state:      ./scripts/dut_collector.sh collect
  - Run benchmark suite:    sudo ./scripts/benchmark_suite.sh all
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

    local foreign_ip="${1:-${FOREIGN_QUERIER_IP:-192.168.1.250}}"
    local lan_iface="${2:-${LAN_IF:-${LAN_BRIDGE}}}"


    printf '==============================================================================\n'
    printf '   FOREIGN LAN QUERIER INJECTION & BEHAVIOR BENCHMARK                         \n'
    printf '==============================================================================\n'
    printf 'LAN Interface:      %s\n' "${lan_iface}"
    printf 'Foreign Querier IP: %s\n' "${foreign_ip}"
    printf '%s\n' '------------------------------------------------------------------------------'

    if netns_exists "${CLIENT1_NAME:-ns-stb1}"; then
        log_info "Injecting 5 foreign IGMP General Queries from IP ${foreign_ip} via namespace ${CLIENT1_NAME} (eth0)..."
        ip netns exec "${CLIENT1_NAME}" python3 "${SCRIPT_DIR}/../tools/igmp_query.py" \
            --interface eth0 \
            --src-ip "${foreign_ip}" \
            --rate-pps 1 \
            --duration-sec 5
        log_info "Injection complete."
        return 0
    fi

    require_test_if_present "${lan_iface}"

    log_info "Injecting 5 foreign IGMP General Queries from IP ${foreign_ip} on ${lan_iface}..."
    python3 "${SCRIPT_DIR}/../tools/igmp_query.py" \
        --interface "${lan_iface}" \
        --src-ip "${foreign_ip}" \
        --rate-pps 1 \
        --duration-sec 5

    log_info "Injection complete."
    log_info "Observe whether router continues sending queries or yields querier election."
    log_info "Inspect router state via: ./scripts/dut_collector.sh collect"
}

main "$@"
