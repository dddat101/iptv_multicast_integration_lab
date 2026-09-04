#!/usr/bin/env bash
# ==============================================================================
# MULTICAST GROUP CAPACITY SCALE BENCHMARK
# Joins N distinct multicast groups and verifies router snooping/forwarding capacity
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

main() {
    load_config

    local group_prefix="${SCALE_GROUP_PREFIX:-239.100.1}"
    local count="${SCALE_GROUP_COUNT:-32}"
    local hold_sec="${SCALE_HOLD_SEC:-15}"
    local groups="${group_prefix}.1-${count}"

    printf '==============================================================================\n'
    printf '   MULTICAST GROUP CAPACITY SCALE BENCHMARK (JOIN %s GROUPS)                  \n' "${count}"
    printf '==============================================================================\n'

    local iface=""
    local if_ip=""

    # Ensure kernel allows joining requested number of groups (default Linux limit is 20)
    local target_memberships=$((count + 32))
    if [[ -w /proc/sys/net/ipv4/igmp_max_memberships ]]; then
        echo "${target_memberships}" > /proc/sys/net/ipv4/igmp_max_memberships 2>/dev/null || true
    fi

    # Determine execution context (LAN namespace or host physical LAN interface)
    if netns_exists "${CLIENT1_NAME:-ns-stb1}"; then
        ip -n "${CLIENT1_NAME}" sysctl -w net.ipv4.igmp_max_memberships="${target_memberships}" >/dev/null 2>&1 || true
        if_ip="$(ip -n "${CLIENT1_NAME}" -4 -o addr show dev eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)"
        if [[ -n "${if_ip}" ]]; then
            log_info "Running scale join from namespace ${CLIENT1_NAME} (IP: ${if_ip})..."
            ip netns exec "${CLIENT1_NAME}" python3 "${SCRIPT_DIR}/../tools/igmp_client.py" \
                --interface-ip "${if_ip}" \
                --groups "${groups}" \
                --hold-sec "${hold_sec}"

            log_info "Scale Benchmark Completed: ${count} groups joined for ${hold_sec}s."
            return 0
        fi
    fi

    # Fallback: Host LAN interface or bridge
    iface="${LAN_IF:-${LAN_BRIDGE}}"
    if_ip="$(ip -4 -o addr show dev "${iface}" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)"
    [[ -n "${if_ip}" ]] || die "Unable to determine IPv4 address for LAN interface ${iface}."

    log_info "Running scale join on host interface ${iface} (IP: ${if_ip})..."
    python3 "${SCRIPT_DIR}/../tools/igmp_client.py" \
        --interface-ip "${if_ip}" \
        --groups "${groups}" \
        --hold-sec "${hold_sec}"

    log_info "Scale Benchmark Completed: ${count} groups joined for ${hold_sec}s."
    log_info "Inspect router group membership tables via ./scripts/dut_collector.sh"
}

main "$@"
