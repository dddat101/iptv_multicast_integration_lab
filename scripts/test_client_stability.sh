#!/usr/bin/env bash
# ==============================================================================
# MULTI-CLIENT STABILITY & FAST-LEAVE ISOLATION BENCHMARK
# Evaluates Fast Leave isolation (RFC 4541) and concurrent multi-client zapping soak
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
    cat <<'USAGE'
Usage:
  sudo ./scripts/test_client_stability.sh [all|fast-leave|churn-soak] [options]

Modes:
  all         Run both Fast Leave isolation and Concurrent Zapping soak [Default]
  fast-leave  Verify N-1 steady clients maintain 0 loss while 1 client churns
  churn-soak  Concurrent channel zapping across all N clients

Options:
  --cycles <N>           Churn cycles for churner client in fast-leave test [Default: 20]
  --churn-interval <ms>  Interval between join/leave in milliseconds [Default: 100]
  --soak-duration <sec>  Duration for multi-client zapping soak [Default: 20]
  --groups <range>       Channels for zapping soak [Default: 239.100.1.1-8]
  --group <ip>           Channel for fast-leave isolation test [Default: 239.10.10.10]
  -h, --help             Show this help message

Examples:
  sudo ./scripts/test_client_stability.sh all
  sudo ./scripts/test_client_stability.sh fast-leave --cycles 30
  sudo ./scripts/test_client_stability.sh churn-soak --soak-duration 30
USAGE
}

cleanup_stability() {
    stop_pidfile "${STATE_DIR}/stab_sender.pid" || true
    for p in "${STATE_DIR}"/stab_*.pid; do
        [[ -f "${p}" ]] && stop_pidfile "${p}" || true
    done
}

run_fast_leave_isolation() {
    local group="${1:-${MCAST_GROUP:-239.10.10.10}}"
    local churn_cycles="${2:-20}"
    local churn_interval="${3:-100}"
    local rate=1000
    local payload=1200

    printf '\n==============================================================================\n'
    printf '   TEST 1: MULTI-CLIENT FAST LEAVE ISOLATION VERIFICATION (RFC 4541)          \n'
    printf '==============================================================================\n'
    printf 'Stream Group:       %s\n' "${group}"
    printf 'Steady Rate:        %d pps (%d bytes/pkt)\n' "${rate}" "${payload}"
    printf 'Churn Cycles:       %d cycles (@ %d ms interval)\n' "${churn_cycles}" "${churn_interval}"
    printf '%s\n' '------------------------------------------------------------------------------'

    local -a all_clients=()
    local names
    names="$(get_active_client_names)"
    while IFS= read -r ns; do
        [[ -n "${ns}" ]] && all_clients+=("${ns}")
    done <<< "${names}"

    local total_clients=${#all_clients[@]}
    if (( total_clients < 2 )); then
        log_warn "At least 2 client namespaces required for Fast Leave isolation test (current: ${total_clients})."
        log_warn "Please instantiate >= 2 clients with: sudo ./scripts/setup.sh -n 3"
        return 1
    fi

    # Designate last client as churner, all others as steady receivers
    local churner="${all_clients[$(( total_clients - 1 ))]}"
    local -a steady_clients=("${all_clients[@]:0:$(( total_clients - 1 ))}")

    local steady_str
    steady_str="$(printf '%s ' "${steady_clients[@]}")"
    steady_str="${steady_str% }"
    log_info "Active clients: ${total_clients} total"
    log_info "  -> Steady Receivers (${#steady_clients[@]}): ${steady_str}"
    log_info "  -> Churner Client:   ${churner}"

    # 1. Determine WAN sender IP & start continuous sequence sender
    local wan_ip=""
    if netns_exists "${SERVER_NAME:-ns-server}"; then
        wan_ip="$(ip -n "${SERVER_NAME}" -4 -o addr show dev eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)"
        if [[ -n "${wan_ip}" ]]; then
            nohup ip netns exec "${SERVER_NAME}" python3 "${SCRIPT_DIR}/../tools/mcast_sender.py" \
                --interface-ip "${wan_ip}" \
                --groups "${group}" \
                --port "${MCAST_PORT:-5000}" \
                --payload-bytes "${payload}" \
                --rate-pps "${rate}" \
                --duration-sec 60 \
                >"${LOG_DIR}/stab_sender.log" 2>&1 &
            echo "$!" > "${STATE_DIR}/stab_sender.pid"
        fi
    fi

    if [[ -z "${wan_ip}" ]]; then
        local wan_iface="${WAN_IF:-${WAN_BRIDGE}}"
        wan_ip="$(ip -4 -o addr show dev "${wan_iface}" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)"
        [[ -n "${wan_ip}" ]] || die "Unable to determine WAN IPv4 address for sender on ${wan_iface}."

        nohup python3 "${SCRIPT_DIR}/../tools/mcast_sender.py" \
            --interface-ip "${wan_ip}" \
            --groups "${group}" \
            --port "${MCAST_PORT:-5000}" \
            --payload-bytes "${payload}" \
            --rate-pps "${rate}" \
            --duration-sec 60 \
            >"${LOG_DIR}/stab_sender.log" 2>&1 &
        echo "$!" > "${STATE_DIR}/stab_sender.pid"
    fi

    sleep 1

    # 2. Start receivers on steady clients
    log_info "Starting steady multicast receivers on ${#steady_clients[@]} client(s)..."
    local -a steady_pids=()
    for s_name in "${steady_clients[@]}"; do
        local s_ip
        s_ip="$(ip -n "${s_name}" -4 -o addr show dev eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)"
        [[ -n "${s_ip}" ]] || continue

        local s_log="${LOG_DIR}/stab_steady_${s_name}.log"
        nohup ip netns exec "${s_name}" python3 "${SCRIPT_DIR}/../tools/mcast_receiver.py" \
            --interface-ip "${s_ip}" \
            --groups "${group}" \
            --port "${MCAST_PORT:-5000}" \
            --duration-sec 25 \
            >"${s_log}" 2>&1 &
        local p=$!
        echo "${p}" > "${STATE_DIR}/stab_steady_${s_name}.pid"
        steady_pids+=("${p}")
        log_info "  -> Steady client ${s_name} (IP: ${s_ip}) listening [PID ${p}]"
    done

    # Allow receivers to stabilize and receive stream
    sleep 3

    # 3. Trigger rapid Join/Leave churn on churner client
    local c_ip
    c_ip="$(ip -n "${churner}" -4 -o addr show dev eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)"
    [[ -n "${c_ip}" ]] || die "Churner ${churner} has no IPv4 on eth0."

    log_info "Triggering ${churn_cycles} rapid Join/Leave cycles from churner ${churner} (IP: ${c_ip})..."
    ip netns exec "${churner}" python3 "${SCRIPT_DIR}/../tools/igmp_client.py" \
        --interface-ip "${c_ip}" \
        --groups "${group}" \
        --interval-ms "${churn_interval}" \
        --cycles "${churn_cycles}" || log_warn "Churn client reported exit code $?"

    log_info "Churn cycles finished. Sampling steady receivers for 3 more seconds..."
    sleep 3

    # Stop steady receivers
    for p in "${steady_pids[@]}"; do
        kill -INT "${p}" 2>/dev/null || true
        wait "${p}" 2>/dev/null || true
    done

    stop_pidfile "${STATE_DIR}/stab_sender.pid" || true

    # 4. Check results of steady clients
    printf '\n=========================================================================================================\n'
    printf '                         FAST LEAVE ISOLATION RESULTS (STEADY CLIENTS)                                   \n'
    printf '=========================================================================================================\n'
    printf '%-14s | %-16s | %10s | %10s | %12s | %s\n' \
           "Client" "Client IP" "Received" "Missing" "Loss Ratio" "Isolation Status"
    printf '%s\n' '---------------------------------------------------------------------------------------------------------'

    local isolation_passed=1
    for s_name in "${steady_clients[@]}"; do
        local s_log="${LOG_DIR}/stab_steady_${s_name}.log"
        local s_ip
        s_ip="$(ip -n "${s_name}" -4 -o addr show dev eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || echo '<none>')"

        local rec mis loss_ratio pass_status
        rec="$(awk -F= '$1 == "received_packets" {print $2}' "${s_log}" 2>/dev/null || echo "0")"
        mis="$(awk -F= '$1 == "missing_packets" {print $2}' "${s_log}" 2>/dev/null || echo "0")"
        loss_ratio="$(awk -F= '$1 == "loss_ratio" {print $2}' "${s_log}" 2>/dev/null || echo "1.0")"
        pass_status="$(awk -F= '$1 == "loss_criteria_pass" {print $2}' "${s_log}" 2>/dev/null || echo "false")"

        rec="${rec:-0}"
        mis="${mis:-0}"

        local verdict="PASS"
        if [[ "${pass_status}" != "true" || "${rec}" -eq 0 ]]; then
            verdict="FAIL (INTERRUPTED)"
            isolation_passed=0
        fi

        printf '%-14s | %-16s | %10s | %10s | %12s | %s\n' \
               "${s_name}" "${s_ip}" "${rec}" "${mis}" "${loss_ratio}" "${verdict}"
    done

    printf '=========================================================================================================\n'
    if (( isolation_passed == 1 )); then
        log_info "FAST LEAVE ISOLATION VERDICT: PASS"
        log_info "No stream interruption observed on steady clients during rapid churn of ${churner}."
    else
        log_warn "FAST LEAVE ISOLATION VERDICT: FAIL"
        log_warn "Stream disruption detected on steady clients when peer client churned!"
    fi
    printf '=========================================================================================================\n'

    return $(( 1 - isolation_passed ))
}

run_concurrent_zapping_soak() {
    local groups="${1:-239.100.1.1-8}"
    local duration="${2:-20}"
    local interval=500

    printf '\n==============================================================================\n'
    printf '   TEST 2: CONCURRENT MULTI-CLIENT CHANNEL ZAPPING SOAK                       \n'
    printf '==============================================================================\n'
    printf 'Zapping Range:      %s\n' "${groups}"
    printf 'Soak Duration:      %d seconds\n' "${duration}"
    printf 'Zapping Pace:       ~%d ms per channel zap\n' "${interval}"
    printf '%s\n' '------------------------------------------------------------------------------'

    local -a clients=()
    local names
    names="$(get_active_client_names)"
    while IFS= read -r ns; do
        [[ -n "${ns}" ]] && clients+=("${ns}")
    done <<< "${names}"

    local total_clients=${#clients[@]}
    ((${total_clients} > 0)) || die "No active client namespaces found."

    log_info "Launching concurrent zappers across all ${total_clients} client namespaces..."
    local -a zap_pids=()
    for c_name in "${clients[@]}"; do
        local c_ip
        c_ip="$(ip -n "${c_name}" -4 -o addr show dev eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)"
        [[ -n "${c_ip}" ]] || continue

        local z_log="${LOG_DIR}/stab_zap_${c_name}.log"
        nohup ip netns exec "${c_name}" python3 "${SCRIPT_DIR}/../tools/igmp_client.py" \
            --interface-ip "${c_ip}" \
            --groups "${groups}" \
            --interval-ms "${interval}" \
            --hold-sec "${duration}" \
            --zap \
            --random \
            >"${z_log}" 2>&1 &
        local p=$!
        echo "${p}" > "${STATE_DIR}/stab_zap_${c_name}.pid"
        zap_pids+=("${p}")
        log_info "  -> Client ${c_name} (IP: ${c_ip}) zapping [PID ${p}]"
    done

    log_info "All zappers active. Soaking for ${duration}s..."
    for p in "${zap_pids[@]}"; do
        wait "${p}" 2>/dev/null || true
    done

    sleep 1

    printf '\n==============================================================================\n'
    printf '                 CONCURRENT ZAPPING SOAK SUMMARY                              \n'
    printf '==============================================================================\n'
    printf '%-14s | %-16s | %10s | %s\n' "Client" "Client IP" "Total Zaps" "Status"
    printf '%s\n' '------------------------------------------------------------------------------'

    local soak_passed=1
    for c_name in "${clients[@]}"; do
        local z_log="${LOG_DIR}/stab_zap_${c_name}.log"
        local c_ip
        c_ip="$(ip -n "${c_name}" -4 -o addr show dev eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || echo '<none>')"

        local zaps
        zaps="$(awk -F= '$1 ~ /zaps/ {print $2}' "${z_log}" 2>/dev/null | awk '{print $1}' || echo "0")"
        if [[ -z "${zaps}" || "${zaps}" == "0" ]]; then
            zaps="$(grep -c "ZAP JOIN" "${z_log}" 2>/dev/null || echo "0")"
        fi

        local status="PASS"
        if (( zaps == 0 )); then
            status="FAIL (NO ZAPS)"
            soak_passed=0
        fi

        printf '%-14s | %-16s | %10s | %s\n' "${c_name}" "${c_ip}" "${zaps}" "${status}"
    done

    printf '==============================================================================\n'
    if (( soak_passed == 1 )); then
        log_info "CONCURRENT ZAPPING SOAK VERDICT: PASS (Router remained stable across all clients)"
    else
        log_warn "CONCURRENT ZAPPING SOAK VERDICT: FAIL (Zapper failures detected)"
    fi
    printf '==============================================================================\n'

    return $(( 1 - soak_passed ))
}

main() {
    for arg in "$@"; do
        if [[ "${arg}" == "-h" || "${arg}" == "--help" ]]; then
            usage
            exit 0
        fi
    done

    load_config

    local mode="all"
    if (( $# > 0 )) && [[ "$1" =~ ^(all|fast-leave|churn-soak)$ ]]; then
        mode="$1"
        shift
    fi

    local cycles=20
    local churn_interval=100
    local soak_duration=20
    local zap_groups="239.100.1.1-8"
    local single_group="${MCAST_GROUP:-239.10.10.10}"

    while (( $# > 0 )); do
        case "$1" in
            --cycles)          cycles="$2"; shift 2 ;;
            --churn-interval)  churn_interval="$2"; shift 2 ;;
            --soak-duration)   soak_duration="$2"; shift 2 ;;
            --groups)          zap_groups="$2"; shift 2 ;;
            --group)           single_group="$2"; shift 2 ;;
            -h|--help)         usage; exit 0 ;;
            *)                 usage; exit 2 ;;
        esac
    done

    require_root
    require_cmd python3

    trap cleanup_stability EXIT INT TERM

    local fl_res=0
    local cs_res=0

    case "${mode}" in
        all)
            run_fast_leave_isolation "${single_group}" "${cycles}" "${churn_interval}" || fl_res=1
            sleep 2
            run_concurrent_zapping_soak "${zap_groups}" "${soak_duration}" || cs_res=1
            ;;
        fast-leave)
            run_fast_leave_isolation "${single_group}" "${cycles}" "${churn_interval}" || fl_res=1
            ;;
        churn-soak)
            run_concurrent_zapping_soak "${zap_groups}" "${soak_duration}" || cs_res=1
            ;;
    esac

    cleanup_stability
    trap - EXIT INT TERM

    if (( fl_res == 0 && cs_res == 0 )); then
        return 0
    fi
    return 1
}

main "$@"
