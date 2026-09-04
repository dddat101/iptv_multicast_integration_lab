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

main() {
    load_config

    local foreign_ip="${FOREIGN_QUERIER_IP:-192.168.1.250}"
    local lan_iface="${LAN_IF:-${LAN_BRIDGE}}"

    printf '==============================================================================\n'
    printf '   FOREIGN LAN QUERIER INJECTION & BEHAVIOR BENCHMARK                         \n'
    printf '==============================================================================\n'
    printf 'LAN Interface:      %s\n' "${lan_iface}"
    printf 'Foreign Querier IP: %s\n' "${foreign_ip}"
    printf '------------------------------------------------------------------------------\n'

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
