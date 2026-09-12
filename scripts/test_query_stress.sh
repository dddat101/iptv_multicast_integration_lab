#!/usr/bin/env bash
# ==============================================================================
# HIGH-RATE GROUP-SPECIFIC QUERY STRESS BENCHMARK
# Sends Group-Specific Queries addressed to multicast group at elevated rates
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
    cat <<'USAGE'
Description:
  Sends IGMP Group-Specific Queries addressed to a target multicast group
  at elevated packet rates on WAN to stress test router querier and IGMP processing.

Usage:
  ./scripts/test_query_stress.sh [options] [multicast_group] [rate_pps] [duration_sec]

Arguments / Options:
  multicast_group   Target multicast group (default: MCAST_GROUP or 239.10.10.10)
  rate_pps          Query packet rate in queries/sec (default: 250)
  duration_sec      Duration in seconds (default: 10)
  -h, --help        Show this help message

Examples:
  ./scripts/test_query_stress.sh
  ./scripts/test_query_stress.sh 239.10.10.10 500 5

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

    local group="${1:-${MCAST_GROUP:-239.10.10.10}}"
    local rate="${2:-${QUERY_STRESS_RATE:-250}}"
    local duration="${3:-${QUERY_STRESS_DURATION:-10}}"


    printf '==============================================================================\n'
    printf '   HIGH-RATE GROUP-SPECIFIC QUERY STRESS (%s @ %d PPS)                        \n' "${group}" "${rate}"
    printf '==============================================================================\n'

    # Queries are transmitted on the WAN control plane or WAN interface towards router
    local iface=""
    if ns_exists "${WAN_NS:-ns-wan}"; then
        log_info "Injecting ${rate} qps queries from WAN namespace ${WAN_NS} via eth0..."
        ip netns exec "${WAN_NS}" python3 "${SCRIPT_DIR}/../tools/igmp_query.py" \
            --interface eth0 \
            --group "${group}" \
            --rate-pps "${rate}" \
            --duration-sec "${duration}"
        log_info "Query Stress Benchmark Completed."
        return 0
    fi

    iface="${WAN_IF:-${WAN_BRIDGE}}"
    require_test_if_present "${iface}"

    log_info "Injecting ${rate} qps queries on WAN interface ${iface}..."
    python3 "${SCRIPT_DIR}/../tools/igmp_query.py" \
        --interface "${iface}" \
        --group "${group}" \
        --rate-pps "${rate}" \
        --duration-sec "${duration}"

    log_info "Query Stress Benchmark Completed."
}

main "$@"
