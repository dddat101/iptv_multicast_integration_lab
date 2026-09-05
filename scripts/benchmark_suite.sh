#!/usr/bin/env bash
# ==============================================================================
# IPTV MULTICAST & IGMP BENCHMARK / RFC VERIFICATION SUITE
# Automated end-to-end qualification suite for multicast routers & gateways
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
    cat <<'USAGE'
Usage:
  ./scripts/benchmark_suite.sh [all|quality|stability|scale|churn|stress|loss|querier|diagnostics|pcap]

Benchmarks:
  all          Execute all benchmark tests and generate comprehensive report
  quality      Multi-client concurrent packet loss & QoS benchmark
  stability    Multi-client Fast Leave isolation & zapping soak benchmark
  scale        Multicast group capacity scale benchmark
  churn        Rapid Join/Leave churn stability benchmark
  stress       High-rate Group-Specific Query stress benchmark
  loss         Multi-group UDP multicast packet loss measurement
  querier      Foreign LAN Querier injection & election benchmark
  diagnostics  Collect router multicast routing and snooping state
  pcap         Inspect packet capture headers and timing metrics
USAGE
}

print_header() {
    printf '\n==============================================================================\n'
    printf '        IPTV MULTICAST & IGMP BENCHMARK / RFC VERIFICATION SUITE               \n'
    printf '==============================================================================\n\n'
}

run_all_benchmarks() {
    print_header
    local report_file="${LOG_DIR}/benchmark_report_$(date '+%Y%m%d_%H%M%S').md"
    mkdir -p "${LOG_DIR}"

    log_info "Starting Automated Multicast Benchmark Suite..."
    log_info "Execution started at: $(date '+%Y-%m-%d %H:%M:%S')"

    local -a test_names=()
    local -a test_standards=()
    local -a test_durations=()
    local -a test_statuses=()
    local -a test_notes=()

    local total_steps=7

    run_step() {
        local step_num="$1"
        local name="$2"
        local standard="$3"
        local pass_note="$4"
        local fail_note="$5"
        shift 5
        local -a cmd=("$@")

        printf '\n'
        log_info "------------------------------------------------------------------------------"
        log_info "Step ${step_num}/${total_steps}: ${name} (${standard})"
        log_info "------------------------------------------------------------------------------"

        local t0 t1 elapsed status note
        t0=$(date +%s)

        if "${cmd[@]}"; then
            status="PASS"
            note="${pass_note}"
            log_info "Result: ${name} -> PASS"
        else
            status="FAIL"
            note="${fail_note}"
            log_warn "Result: ${name} -> FAIL / WARNING"
        fi

        t1=$(date +%s)
        elapsed="$(( t1 - t0 ))s"

        test_names+=("${name}")
        test_standards+=("${standard}")
        test_durations+=("${elapsed}")
        test_statuses+=("${status}")
        test_notes+=("${note}")
    }

    # Step 1: Multi-client Quality benchmark
    local c_active
    c_active="$(get_active_client_names 2>/dev/null | grep -c . || echo "0")"
    local q_pass_note="Zero packet loss across active clients"
    if (( c_active > 0 )); then
        q_pass_note="Zero packet loss across ${c_active} clients"
    fi
    run_step 1 \
        "Multi-Client Quality" \
        "RFC 4541 / Data Plane" \
        "${q_pass_note}" \
        "Packet loss or inactive receivers detected" \
        "${SCRIPT_DIR}/test_client_quality.sh"

    # Step 2: Multi-client Stability benchmark
    run_step 2 \
        "Multi-Client Stability" \
        "RFC 4541 / Fast Leave" \
        "Fast leave isolation & zapping soak stable" \
        "Stream disruption or zapper error detected" \
        "${SCRIPT_DIR}/test_client_stability.sh"

    # Step 3: Churn benchmark
    run_step 3 \
        "Rapid Join/Leave Churn" \
        "RFC 2236 / Control Plane" \
        "${CHURN_CYCLES:-30} churn cycles completed (${CHURN_INTERVAL_MS:-100}ms)" \
        "Churn failure or timeout encountered" \
        "${SCRIPT_DIR}/test_churn.sh"

    # Step 4: Scale benchmark
    run_step 4 \
        "Group Capacity Scale" \
        "RFC 2236 / Table Scale" \
        "${SCALE_GROUP_COUNT:-32} groups joined and held for ${SCALE_HOLD_SEC:-15}s" \
        "Scale join limit or error encountered" \
        "${SCRIPT_DIR}/test_scale.sh"

    # Step 5: Query stress benchmark
    run_step 5 \
        "High-Rate Query Stress" \
        "RFC 2236/3376 Robustness" \
        "${QUERY_STRESS_RATE:-250} queries/sec sustained load evaluated" \
        "Query stress injection failed or errored" \
        "${SCRIPT_DIR}/test_query_stress.sh"

    # Step 6: Foreign Querier benchmark
    run_step 6 \
        "Foreign Querier Election" \
        "RFC 2236 Sec 3 Election" \
        "Foreign querier injected; election audit complete" \
        "Foreign querier injection failed" \
        "${SCRIPT_DIR}/test_foreign_querier.sh"

    # Step 7: PCAP Header & Timing Analysis
    if compgen -G "${CAPTURE_DIR}/*.pcap*" >/dev/null; then
        run_step 7 \
            "PCAP Timing & Compliance" \
            "RFC 2236/2474 Audit" \
            "Traffic headers, ToS/DF, and latency verified" \
            "Header or latency deviation observed" \
            "${SCRIPT_DIR}/verify_capture.sh" compliance
    else
        printf '\n'
        log_info "------------------------------------------------------------------------------"
        log_info "Step 7/${total_steps}: PCAP Timing & Compliance (RFC 2236/2474 Audit)"
        log_info "------------------------------------------------------------------------------"
        log_warn "No packet capture (.pcap) found in ${CAPTURE_DIR}. Step skipped."
        test_names+=("PCAP Timing & Compliance")
        test_standards+=("RFC 2236/2474 Audit")
        test_durations+=("0s")
        test_statuses+=("SKIPPED")
        test_notes+=("No capture file found in captures/")
    fi

    # Compute overall statistics
    local total_count=${#test_names[@]}
    local passed_count=0
    local failed_count=0
    local skipped_count=0

    for (( i=0; i<total_count; i++ )); do
        case "${test_statuses[i]}" in
            PASS)    (( passed_count++ )) ;;
            SKIPPED) (( skipped_count++ )) ;;
            *)       (( failed_count++ )) ;;
        esac
    done

    local overall_verdict="PASS"
    if (( failed_count > 0 )); then
        overall_verdict="FAIL / DEVIATIONS DETECTED"
    fi

    # Display dynamically rendered and aligned table in terminal
    printf '\n%s\n' '============================================================================================================================'
    printf '                                          PROTOCOL & PERFORMANCE BENCHMARK MATRIX\n'
    printf '%s\n' '============================================================================================================================'
    printf ' %-2s | %-26s | %-24s | %10s | %-8s | %s\n' \
           "#" "Test / Benchmark" "Target Standard / Scope" "Duration" "Status" "Evidence / Notes"
    printf '%s\n' '----+----------------------------+--------------------------+------------+----------+---------------------------------------'

    for (( i=0; i<total_count; i++ )); do
        printf ' %-2d | %-26s | %-24s | %10s | %-8s | %s\n' \
               "$(( i + 1 ))" \
               "${test_names[i]}" \
               "${test_standards[i]}" \
               "${test_durations[i]}" \
               "${test_statuses[i]}" \
               "${test_notes[i]}"
    done

    printf '%s\n' '============================================================================================================================'
    printf ' OVERALL BENCHMARK VERDICT: %s (Passed: %d, Failed: %d, Skipped: %d)\n' \
           "${overall_verdict}" "${passed_count}" "${failed_count}" "${skipped_count}"
    printf '%s\n\n' '============================================================================================================================'

    # Write identical dynamic summary to the Markdown report file
    {
        printf '# IPTV Multicast & IGMP Benchmark Report\n\n'
        printf '%s\n' "- **Execution Date:** $(date '+%Y-%m-%d %H:%M:%S')"
        printf '%s\n' "- **Lab Project Root:** \`${PROJECT_ROOT}\`"
        printf '%s\n\n' "- **Overall Verdict:** **${overall_verdict}** (${passed_count} Passed, ${failed_count} Failed, ${skipped_count} Skipped)"

        printf '## 1. Protocol & Performance Benchmark Matrix\n\n'
        printf '| # | Test / Benchmark | Target Standard / Scope | Duration | Status | Evidence / Notes |\n'
        printf '|---|------------------|-------------------------|:--------:|:------:|------------------|\n'

        for (( i=0; i<total_count; i++ )); do
            local md_status="**${test_statuses[i]}**"
            if [[ "${test_statuses[i]}" == "SKIPPED" ]]; then
                md_status="_SKIPPED_"
            fi

            printf '| %d | %s | %s | %s | %s | %s |\n' \
                   "$(( i + 1 ))" \
                   "${test_names[i]}" \
                   "${test_standards[i]}" \
                   "${test_durations[i]}" \
                   "${md_status}" \
                   "${test_notes[i]}"
        done
        printf '\n'
    } > "${report_file}"

    log_info "Benchmark Suite completed. Report written to: ${report_file}"

    if (( failed_count > 0 )); then
        return 1
    fi
    return 0
}

main() {
    load_config
    local suite="${1:-all}"

    case "${suite}" in
        all)
            run_all_benchmarks
            ;;
        quality)
            "${SCRIPT_DIR}/test_client_quality.sh" "${@:2}"
            ;;
        stability)
            "${SCRIPT_DIR}/test_client_stability.sh" "${@:2}"
            ;;
        scale)
            "${SCRIPT_DIR}/test_scale.sh"
            ;;
        churn)
            "${SCRIPT_DIR}/test_churn.sh"
            ;;
        stress)
            "${SCRIPT_DIR}/test_query_stress.sh"
            ;;
        loss)
            "${SCRIPT_DIR}/test_packet_loss.sh"
            ;;
        querier)
            "${SCRIPT_DIR}/test_foreign_querier.sh"
            ;;
        diagnostics)
            "${SCRIPT_DIR}/dut_collector.sh" collect
            ;;
        pcap)
            "${SCRIPT_DIR}/verify_capture.sh" compliance "${2:-}"
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
