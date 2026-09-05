#!/usr/bin/env bash
# ==============================================================================
# MULTI-CLIENT MULTICAST QUALITY BENCHMARK
# Concurrently evaluates packet loss, throughput, and QoS across N STB clients
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
    cat <<'USAGE'
Usage:
  sudo ./scripts/test_client_quality.sh [options]

Options:
  -c, --clients <list|all> Comma-separated client indices/names or 'all' [Default: all]
  -g, --groups <groups>    Multicast group(s) to test (e.g. 239.100.1.1-4 or 239.10.10.10) [Default: 239.100.1.1-4]
  -r, --rate <pps>         Total packet rate in packets/sec [Default: 1000]
  -s, --payload <bytes>    UDP payload size in bytes [Default: 1200]
  -d, --duration <sec>     Test duration in seconds [Default: 10]
  -p, --port <port>        UDP port [Default: 5000]
  -h, --help               Show this help message

Examples:
  sudo ./scripts/test_client_quality.sh
  sudo ./scripts/test_client_quality.sh --clients 1,2,3 --duration 15
  sudo ./scripts/test_client_quality.sh --rate 2000 --groups 239.100.1.1-8
USAGE
}

cleanup_quality_test() {
    stop_pidfile "${STATE_DIR}/quality_sender.pid" || true
    for p in "${STATE_DIR}"/quality_client_*.pid; do
        [[ -f "${p}" ]] && stop_pidfile "${p}" || true
    done
}

main() {
    load_config

    local target_clients="all"
    local groups="${QUALITY_TEST_GROUPS:-239.100.1.1-4}"
    local rate="${QUALITY_TEST_RATE_PPS:-1000}"
    local payload="${QUALITY_TEST_PAYLOAD_BYTES:-1200}"
    local duration="${QUALITY_TEST_DURATION:-10}"
    local port="${MCAST_PORT:-5000}"

    while (( $# > 0 )); do
        case "$1" in
            -c|--clients)   target_clients="$2"; shift 2 ;;
            -g|--groups)    groups="$2"; shift 2 ;;
            -r|--rate)      rate="$2"; shift 2 ;;
            -s|--payload)   payload="$2"; shift 2 ;;
            -d|--duration)  duration="$2"; shift 2 ;;
            -p|--port)      port="$2"; shift 2 ;;
            -h|--help)      usage; exit 0 ;;
            *)              usage; exit 2 ;;
        esac
    done

    require_root
    require_cmd python3

    # Resolve target client namespaces
    local -a clients=()
    if [[ "${target_clients}" == "all" ]]; then
        local names
        names="$(get_active_client_names)"
        while IFS= read -r ns; do
            [[ -n "${ns}" ]] && clients+=("${ns}")
        done <<< "${names}"
    else
        IFS=',' read -ra raw_targets <<< "${target_clients}"
        for t in "${raw_targets[@]}"; do
            t="$(echo "${t}" | tr -d ' ')"
            [[ -z "${t}" ]] && continue
            if [[ "${t}" =~ ^[0-9]+$ ]]; then
                clients+=("$(get_client_name "${t}")")
            else
                clients+=("${t}")
            fi
        done
    fi

    ((${#clients[@]} > 0)) || die "No active STB client namespaces found to test. Run sudo ./scripts/setup.sh first."

    printf '==============================================================================\n'
    printf '        MULTI-CLIENT MULTICAST QUALITY & PERFORMANCE BENCHMARK                \n'
    local client_list
    client_list="$(printf '%s ' "${clients[@]}")"
    client_list="${client_list% }"
    printf 'Tested Clients: %d (%s)\n' "${#clients[@]}" "${client_list}"
    printf 'Groups:         %s\n' "${groups}"
    printf 'Payload Size:   %d bytes\n' "${payload}"
    printf 'Send Rate:      %d packets/sec\n' "${rate}"
    printf 'Duration:       %d seconds\n' "${duration}"
    printf 'Target Port:    %d\n' "${port}"
    printf '%s\n' '------------------------------------------------------------------------------'

    trap cleanup_quality_test EXIT INT TERM

    # 1. Determine WAN sender IP & start sequence generator
    local wan_ip=""
    if netns_exists "${SERVER_NAME:-ns-server}"; then
        wan_ip="$(ip -n "${SERVER_NAME}" -4 -o addr show dev eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)"
        if [[ -n "${wan_ip}" ]]; then
            log_info "Starting WAN multicast sender in ${SERVER_NAME} (IP: ${wan_ip})..."
            nohup ip netns exec "${SERVER_NAME}" python3 "${SCRIPT_DIR}/../tools/mcast_sender.py" \
                --interface-ip "${wan_ip}" \
                --groups "${groups}" \
                --port "${port}" \
                --payload-bytes "${payload}" \
                --rate-pps "${rate}" \
                --duration-sec "$(( duration + 6 ))" \
                >"${LOG_DIR}/quality_sender.log" 2>&1 &
            echo "$!" > "${STATE_DIR}/quality_sender.pid"
        fi
    fi

    if [[ -z "${wan_ip}" ]]; then
        local wan_iface="${WAN_IF:-${WAN_BRIDGE}}"
        wan_ip="$(ip -4 -o addr show dev "${wan_iface}" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)"
        [[ -n "${wan_ip}" ]] || die "Unable to determine WAN IPv4 address for sender on ${wan_iface}."

        log_info "Starting WAN multicast sender on host interface ${wan_iface} (IP: ${wan_ip})..."
        nohup python3 "${SCRIPT_DIR}/../tools/mcast_sender.py" \
            --interface-ip "${wan_ip}" \
            --groups "${groups}" \
            --port "${port}" \
            --payload-bytes "${payload}" \
            --rate-pps "${rate}" \
            --duration-sec "$(( duration + 6 ))" \
            >"${LOG_DIR}/quality_sender.log" 2>&1 &
        echo "$!" > "${STATE_DIR}/quality_sender.pid"
    fi

    sleep 1

    # 2. Launch concurrent receivers in each client namespace
    log_info "Spawning concurrent multicast receivers across ${#clients[@]} client namespaces..."
    local -a client_pids=()
    for c_name in "${clients[@]}"; do
        if ! netns_exists "${c_name}"; then
            log_warn "Namespace '${c_name}' does not exist; skipping."
            continue
        fi

        local c_ip
        c_ip="$(ip -n "${c_name}" -4 -o addr show dev eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)"
        if [[ -z "${c_ip}" ]]; then
            log_warn "Namespace '${c_name}' has no IPv4 on eth0; skipping."
            continue
        fi

        local c_log="${LOG_DIR}/quality_${c_name}.log"
        nohup ip netns exec "${c_name}" python3 "${SCRIPT_DIR}/../tools/mcast_receiver.py" \
            --interface-ip "${c_ip}" \
            --groups "${groups}" \
            --port "${port}" \
            --duration-sec "${duration}" \
            >"${c_log}" 2>&1 &
        local p=$!
        echo "${p}" > "${STATE_DIR}/quality_client_${c_name}.pid"
        client_pids+=("${p}")
        log_info "  -> Client ${c_name} (IP: ${c_ip}) listening [PID ${p}]"
    done

    ((${#client_pids[@]} > 0)) || die "No client receivers could be started."

    log_info "Receivers active. Waiting ${duration}s for stream sampling to complete..."
    for p in "${client_pids[@]}"; do
        wait "${p}" 2>/dev/null || true
    done

    # Allow a brief moment for filesystem write flush
    sleep 0.5

    # 3. Analyze and display results table
    printf '\n=========================================================================================================\n'
    printf '                                MULTI-CLIENT QUALITY BENCHMARK RESULTS                                   \n'
    printf '=========================================================================================================\n'
    printf '%-14s | %-16s | %10s | %10s | %12s | %10s | %s\n' \
           "Client" "Client IP" "Received" "Missing" "Throughput" "Loss Ratio" "Status"
    printf '%s\n' '---------------------------------------------------------------------------------------------------------'

    local all_passed=1
    for c_name in "${clients[@]}"; do
        local c_log="${LOG_DIR}/quality_${c_name}.log"
        local c_ip
        c_ip="$(ip -n "${c_name}" -4 -o addr show dev eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || echo '<none>')"

        if [[ ! -f "${c_log}" ]]; then
            printf '%-14s | %-16s | %10s | %10s | %12s | %10s | %s\n' \
                   "${c_name}" "${c_ip}" "0" "0" "0.00 Mbps" "N/A" "NO DATA"
            all_passed=0
            continue
        fi

        local rec mis ooo loss_ratio pass_status
        rec="$(awk -F= '$1 == "received_packets" {print $2}' "${c_log}" || echo "0")"
        mis="$(awk -F= '$1 == "missing_packets" {print $2}' "${c_log}" || echo "0")"
        loss_ratio="$(awk -F= '$1 == "loss_ratio" {print $2}' "${c_log}" || echo "1.0")"
        pass_status="$(awk -F= '$1 == "loss_criteria_pass" {print $2}' "${c_log}" || echo "false")"

        rec="${rec:-0}"
        mis="${mis:-0}"

        local mbps="0.00 Mbps"
        if (( rec > 0 && duration > 0 )); then
            # Calculate Mbps: (rec * payload * 8) / (duration * 1000000)
            local bits=$(( rec * payload * 8 ))
            mbps="$(awk -v b="${bits}" -v d="${duration}" 'BEGIN { printf "%.2f Mbps", b / (d * 1000000) }')"
        fi

        local verdict="PASS"
        if [[ "${pass_status}" != "true" || "${rec}" -eq 0 ]]; then
            verdict="FAIL"
            all_passed=0
        fi

        printf '%-14s | %-16s | %10s | %10s | %12s | %10s | %s\n' \
               "${c_name}" "${c_ip}" "${rec}" "${mis}" "${mbps}" "${loss_ratio}" "${verdict}"
    done

    printf '=========================================================================================================\n'
    if (( all_passed == 1 )); then
        printf 'OVERALL QUALITY VERDICT: PASS (Zero packet loss observed across all %d clients)\n' "${#clients[@]}"
    else
        printf 'OVERALL QUALITY VERDICT: FAIL (Packet loss or inactive receivers detected)\n'
    fi
    printf '=========================================================================================================\n'

    cleanup_quality_test
    trap - EXIT INT TERM
    return $(( 1 - all_passed ))
}

main "$@"
