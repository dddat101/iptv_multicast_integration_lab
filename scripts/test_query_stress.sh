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

main() {
    load_config

    local group="${1:-${MCAST_GROUP:-239.10.10.10}}"
    local rate="${QUERY_STRESS_RATE:-250}"
    local duration="${QUERY_STRESS_DURATION:-10}"

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
