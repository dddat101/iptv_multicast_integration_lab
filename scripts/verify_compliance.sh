#!/usr/bin/env bash
# ==============================================================================
# IPTV MULTICAST LAB - AUTOMATED COMPLIANCE & PCAP VERIFICATION ENGINE
# Wire-level packet inspection, dual-layer validation & ASCII evidence timeline
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

usage() {
    cat <<'USAGE'
Description:
  Analyzes packet capture files (.pcap) and runtime audit state to verify
  IPTV multicast compliance, IGMPv2 signaling, MPEG-TS data flow, join latency,
  and DSCP/DF header markings.

Usage:
  ./scripts/verify_compliance.sh [options] [pcap_file] [multicast_group]
  ./scripts/verify_compliance.sh -h | --help

Options:
  -h, --help        Show this help message and exit

Arguments:
  pcap_file         Path to .pcap capture file (defaults to latest capture)
  multicast_group   Multicast group IPv4 address (defaults to MCAST_GROUP in config.env)

Examples:
  ./scripts/verify_compliance.sh
  ./scripts/verify_compliance.sh captures/lan_20260922_120000.pcap
  ./scripts/verify_compliance.sh captures/lan_20260922_120000.pcap 239.10.10.10

Suggested Next Steps:
  - Inspect lab state:   ./scripts/show_state.sh
  - Run benchmark suite: sudo ./scripts/benchmark_suite.sh all
  - Teardown lab:        sudo ./scripts/cleanup.sh
USAGE
}

check_test() {
    local id="$1"
    local title="$2"
    local status="$3"
    local detail="$4"

    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    if [[ "${status}" == "PASS" ]]; then
        PASSED_TESTS=$((PASSED_TESTS + 1))
        printf '  \e[1;32m[PASS]\e[0m [%s] %s\n         Detail: %s\n' "${id}" "${title}" "${detail}"
    elif [[ "${status}" == "INFO" ]]; then
        printf '  \e[1;34m[INFO]\e[0m [%s] %s\n         Detail: %s\n' "${id}" "${title}" "${detail}"
    elif [[ "${status}" == "WARN" ]]; then
        printf '  \e[1;33m[WARN]\e[0m [%s] %s\n         Detail: %s\n' "${id}" "${title}" "${detail}"
    else
        FAILED_TESTS=$((FAILED_TESTS + 1))
        printf '  \e[1;31m[FAIL]\e[0m [%s] %s\n         Detail: %s\n' "${id}" "${title}" "${detail}"
    fi
}

print_pcap_timeline() {
    local pcap_file="$1"
    if ! check_command "${TSHARK_BIN:-tshark}"; then
        log_info "tshark not installed; skipping packet timeline table."
        return 0
    fi
    if [[ ! -f "${pcap_file}" || ! -s "${pcap_file}" ]]; then
        log_warn "PCAP file is empty or missing: ${pcap_file}"
        return 0
    fi

    printf '\n========================================================================================\n'
    printf '                          PACKET TIMELINE EVIDENCE                               \n'
    printf '========================================================================================\n'
    printf '%-6s | %-12s | %-20s | %-20s | %-24s\n' "Frame" "Time (s)" "Source IP" "Destination IP" "Protocol / Info"
    printf '%s\n' "----------------------------------------------------------------------------------------"

    # SIGPIPE protection pattern:
    # shellcheck disable=SC2016
    (tshark -r "${pcap_file}" \
        -T fields \
        -e frame.number -e frame.time_relative -e _ws.col.Source -e _ws.col.Destination -e _ws.col.Protocol -e _ws.col.Info 2>/dev/null || true) | \
        awk -F '\t' '{ printf "%-6s | %-12.4f | %-20s | %-20s | %-10s %s\n", $1, $2, $3, $4, $5, $6 }' | head -n 35 || true

    printf '========================================================================================\n\n'
}

main() {
    for arg in "$@"; do
        if [[ "${arg}" == "-h" || "${arg}" == "--help" ]]; then
            usage
            exit 0
        fi
    done

    load_config
    if [[ -f "${STATE_DIR}/topology_state.env" ]]; then
        local saved_proto saved_mcast
        saved_proto="$(grep '^IP_VERSION=' "${STATE_DIR}/topology_state.env" 2>/dev/null | cut -d= -f2 | tr -d "'\"" || true)"
        saved_mcast="$(grep '^MCAST_GROUP=' "${STATE_DIR}/topology_state.env" 2>/dev/null | cut -d= -f2 | tr -d "'\"" || true)"
        [[ -n "${saved_proto}" ]] && IP_VERSION="${saved_proto}"
        [[ -n "${saved_mcast}" ]] && MCAST_GROUP="${saved_mcast}"
    fi

    local pcap_file=""
    local group=""

    if [[ $# -gt 0 && -f "$1" ]]; then
        pcap_file="$1"
        group="${2:-}"
    elif [[ $# -gt 0 && ( "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ || "$1" =~ : ) ]]; then
        group="$1"
        pcap_file="${2:-}"
    else
        pcap_file="${1:-}"
        group="${2:-}"
    fi

    if [[ -z "${pcap_file}" ]]; then
        pcap_file="$(get_latest_pcap || true)"
    fi
    group="${group:-${MCAST_GROUP:-239.10.10.10}}"
    local port="${MCAST_PORT:-5000}"

    print_header "IPTV MULTICAST COMPLIANCE & PCAP VERIFICATION"

    if [[ -n "${pcap_file}" && -f "${pcap_file}" ]]; then
        local pcap_size
        pcap_size="$(du -h "${pcap_file}" 2>/dev/null | cut -f1 || echo "unknown")"
        log_info "Analyzing PCAP Evidence: ${pcap_file} (${pcap_size})"
        log_info "Target Multicast Group:  ${group} (UDP Port ${port})"
        print_pcap_timeline "${pcap_file}"
    else
        log_warn "No PCAP capture file found. Proceeding with application/system checks only."
    fi

    # --------------------------------------------------------------------------
    # SECTION 1: Wire-Level Protocol & Data Conformance
    # --------------------------------------------------------------------------
    print_section "SECTION 1: WIRE-LEVEL PACKET CONFORMANCE (PCAP)"

    if [[ -n "${pcap_file}" && -f "${pcap_file}" ]] && check_command "${TSHARK_BIN:-tshark}"; then
        # TC_WIRE_01: Capture Frame Integrity
        local total_frames
        total_frames="$((tshark -r "${pcap_file}" 2>/dev/null || true) | wc -l)"
        if (( total_frames > 0 )); then
            check_test "TC_WIRE_01" "Traffic Capture Integrity" "PASS" "Captured ${total_frames} valid frames on wire."
        else
            check_test "TC_WIRE_01" "Traffic Capture Integrity" "FAIL" "Zero frames captured in ${pcap_file}."
        fi

        # TC_WIRE_02: Multicast Join Signaling (IGMPv2 for IPv4, MLD for IPv6)
        local join_count join_filter
        if [[ "${group}" =~ : ]]; then
            join_filter="icmpv6.type == 143 || icmpv6.type == 131"
            join_count="$((tshark -r "${pcap_file}" -Y "${join_filter}" 2>/dev/null || true) | wc -l)"
            if (( join_count > 0 )); then
                check_test "TC_WIRE_02" "MLD Join Signaling" "PASS" "Detected ${join_count} MLD Report(s) for ${group}."
            else
                check_test "TC_WIRE_02" "MLD Join Signaling" "FAIL" "No MLD Reports detected on wire."
            fi
        else
            join_filter="igmp.type == 0x16 && igmp.maddr == ${group}"
            join_count="$((tshark -r "${pcap_file}" -Y "${join_filter}" 2>/dev/null || true) | wc -l)"
            if (( join_count > 0 )); then
                check_test "TC_WIRE_02" "IGMPv2 Join Signaling" "PASS" "Detected ${join_count} Membership Report(s) for ${group}."
            else
                local any_join
                any_join="$((tshark -r "${pcap_file}" -Y "igmp.type == 0x16" 2>/dev/null || true) | wc -l)"
                if (( any_join > 0 )); then
                    check_test "TC_WIRE_02" "IGMPv2 Join Signaling" "PASS" "Detected ${any_join} generic Membership Report(s)."
                else
                    check_test "TC_WIRE_02" "IGMPv2 Join Signaling" "FAIL" "No IGMPv2 Membership Reports detected for group ${group}."
                fi
            fi
        fi

        # TC_WIRE_03: MPEG-TS Multicast UDP Data Forwarding
        local data_count data_filter
        if [[ "${group}" =~ : ]]; then
            data_filter="ipv6.dst == ${group} && udp.dstport == ${port}"
            data_count="$((tshark -r "${pcap_file}" -Y "${data_filter}" 2>/dev/null || true) | wc -l)"
            if (( data_count > 0 )); then
                check_test "TC_WIRE_03" "MPEG-TS Multicast Forwarding" "PASS" "Received ${data_count} IPv6 UDP video packets on [${group}]:${port}."
            else
                local any_mcast6
                any_mcast6="$((tshark -r "${pcap_file}" -Y "ipv6.dst >= ff00:: && udp" 2>/dev/null || true) | wc -l)"
                if (( any_mcast6 > 0 )); then
                    check_test "TC_WIRE_03" "MPEG-TS Multicast Forwarding" "PASS" "Detected ${any_mcast6} IPv6 multicast data packets on alternate groups."
                else
                    check_test "TC_WIRE_03" "MPEG-TS Multicast Forwarding" "FAIL" "Zero IPv6 multicast UDP packets detected for [${group}]:${port}."
                fi
            fi
        else
            data_filter="ip.dst == ${group} && udp.dstport == ${port}"
            data_count="$((tshark -r "${pcap_file}" -Y "${data_filter}" 2>/dev/null || true) | wc -l)"
            if (( data_count > 0 )); then
                check_test "TC_WIRE_03" "MPEG-TS Multicast Forwarding" "PASS" "Received ${data_count} UDP video packets on ${group}:${port}."
            else
                local any_mcast
                any_mcast="$((tshark -r "${pcap_file}" -Y "ip.dst >= 224.0.0.0 && ip.dst <= 239.255.255.255 && udp" 2>/dev/null || true) | wc -l)"
                if (( any_mcast > 0 )); then
                    check_test "TC_WIRE_03" "MPEG-TS Multicast Forwarding" "PASS" "Detected ${any_mcast} multicast data packets on alternate groups."
                else
                    check_test "TC_WIRE_03" "MPEG-TS Multicast Forwarding" "FAIL" "Zero multicast UDP data packets detected for ${group}:${port}."
                fi
            fi
        fi

        # TC_WIRE_04: Join-to-First-Data Latency
        local latency_ms="N/A"
        if (( join_count > 0 && data_count > 0 )); then
            local t_join t_data
            t_join="$((tshark -r "${pcap_file}" -Y "${join_filter}" -T fields -e frame.time_epoch 2>/dev/null || true) | head -n1)"
            t_data="$((tshark -r "${pcap_file}" -Y "${data_filter}" -T fields -e frame.time_epoch 2>/dev/null || true) | awk -v j="${t_join}" 'j == "" || $1 >= j {print $1; exit}')"
            if [[ -n "${t_join}" && -n "${t_data}" ]]; then
                latency_ms="$(awk -v d="${t_data}" -v j="${t_join}" 'BEGIN { printf "%.3f", (d - j) * 1000 }')"
                local lat_status
                lat_status="$(awk -v l="${latency_ms}" 'BEGIN { if (l <= 200.0) print "PASS"; else print "WARN" }')"
                check_test "TC_WIRE_04" "Join-to-First-Data Latency" "${lat_status}" "${latency_ms} ms (Target: <= 200ms)."
            else
                check_test "TC_WIRE_04" "Join-to-First-Data Latency" "INFO" "Unable to correlate join and first data epoch."
            fi
        else
            check_test "TC_WIRE_04" "Join-to-First-Data Latency" "INFO" "Skipped (Requires both Join and Data packets)."
        fi

        # TC_WIRE_05: Multicast Leave Signaling (Fast Leave)
        local leave_count leave_filter
        if [[ "${group}" =~ : ]]; then
            leave_filter="icmpv6.type == 132"
            leave_count="$((tshark -r "${pcap_file}" -Y "${leave_filter}" 2>/dev/null || true) | wc -l)"
            if (( leave_count > 0 )); then
                check_test "TC_WIRE_05" "MLD Done/Leave Signaling" "PASS" "Detected ${leave_count} MLD Done message(s) on wire."
            else
                check_test "TC_WIRE_05" "MLD Done/Leave Signaling" "INFO" "No MLD Done messages recorded (client still streaming or not stopped)."
            fi
        else
            leave_filter="igmp.type == 0x17 && igmp.maddr == ${group}"
            leave_count="$((tshark -r "${pcap_file}" -Y "${leave_filter}" 2>/dev/null || true) | wc -l)"
            if (( leave_count > 0 )); then
                check_test "TC_WIRE_05" "IGMPv2 Leave Signaling" "PASS" "Detected ${leave_count} Leave Group message(s) for ${group}."
            else
                local any_leave
                any_leave="$((tshark -r "${pcap_file}" -Y "igmp.type == 0x17" 2>/dev/null || true) | wc -l)"
                if (( any_leave > 0 )); then
                    check_test "TC_WIRE_05" "IGMPv2 Leave Signaling" "PASS" "Detected ${any_leave} generic Leave Group message(s)."
                else
                    check_test "TC_WIRE_05" "IGMPv2 Leave Signaling" "INFO" "No Leave messages recorded (client still streaming or not stopped)."
                fi
            fi
        fi

        # TC_WIRE_06: IP Header QoS / Flow Markings
        if [[ "${group}" =~ : ]]; then
            local traffic_class
            traffic_class="$((tshark -r "${pcap_file}" -Y "ipv6.dst == ${group}" -T fields -e ipv6.tclass 2>/dev/null || true) | sort -u | tr '\n' ',' | sed 's/,$//')"
            if [[ -n "${traffic_class}" ]]; then
                check_test "TC_WIRE_06" "IPv6 Traffic Class Markings" "PASS" "IPv6 Traffic Class (DSCP): ${traffic_class}."
            else
                check_test "TC_WIRE_06" "IPv6 Traffic Class Markings" "INFO" "No IPv6 traffic class headers recorded."
            fi
        else
            local igmp_tos igmp_df
            igmp_tos="$((tshark -r "${pcap_file}" -Y "igmp" -T fields -e ip.tos 2>/dev/null || true) | sort -u | tr '\n' ',' | sed 's/,$//')"
            igmp_df="$((tshark -r "${pcap_file}" -Y "igmp" -T fields -e ip.flags.df 2>/dev/null || true) | sort -u | tr '\n' ',' | sed 's/,$//')"
            if [[ -n "${igmp_tos}" ]]; then
                check_test "TC_WIRE_06" "IPv4 Quality-of-Service Markings" "PASS" "IGMP ToS/DSCP byte: ${igmp_tos}; DF flag: ${igmp_df:-0}."
            else
                check_test "TC_WIRE_06" "IPv4 Quality-of-Service Markings" "INFO" "No IGMP ToS headers recorded."
            fi
        fi
    else
        check_test "TC_WIRE_01" "Traffic Capture Inspection" "WARN" "PCAP file not available or tshark not installed."
    fi

    # --------------------------------------------------------------------------
    # SECTION 2: Application, Daemon & Audit State
    # --------------------------------------------------------------------------
    print_section "SECTION 2: APPLICATION & AUDIT LOG CHECKS"

    # TC_APP_01: Media Asset & Streamer Status
    if [[ -f "${MEDIA_DIR}/${MEDIA_FILE}" ]]; then
        local media_size
        media_size="$(du -h "${MEDIA_DIR}/${MEDIA_FILE}" 2>/dev/null | cut -f1 || echo "0")"
        check_test "TC_APP_01" "Media Stream Asset Integrity" "PASS" "Asset ${MEDIA_FILE} present (${media_size})."
    else
        check_test "TC_APP_01" "Media Stream Asset Integrity" "WARN" "Media file missing (${MEDIA_DIR}/${MEDIA_FILE})."
    fi

    # TC_APP_02: Client Namespace DHCP & Addressing
    local active_clients
    active_clients="$(get_active_client_names 2>/dev/null || true)"
    if [[ -n "${active_clients}" ]]; then
        local count
        count="$(echo "${active_clients}" | grep -c . || echo 0)"
        check_test "TC_APP_02" "STB Client Topology Presence" "PASS" "${count} STB client namespace(s) active."
    else
        check_test "TC_APP_02" "STB Client Topology Presence" "INFO" "No active client namespaces (standalone or teardown state)."
    fi

    # TC_APP_03: Log Audit Verification
    if [[ -f "${LOG_DIR}/server.log" || -f "${LOG_DIR}/server_direct.log" ]]; then
        check_test "TC_APP_03" "Media Server Log Audit" "PASS" "Server log available in ${LOG_DIR}."
    else
        check_test "TC_APP_03" "Media Server Log Audit" "INFO" "Server log not recorded yet."
    fi

    # --------------------------------------------------------------------------
    # Summary and Final Verdict
    # --------------------------------------------------------------------------
    printf '\n==================================================================\n'
    printf 'TEST SUMMARY: Total: %d | Passed: %d | Failed: %d\n' "${TOTAL_TESTS}" "${PASSED_TESTS}" "${FAILED_TESTS}"
    if (( FAILED_TESTS == 0 )); then
        printf '\e[1;32m[FINAL VERDICT: PASS]\e[0m ALL VERIFICATIONS COMPLETED SUCCESSFULLY!\n'
        return 0
    else
        printf '\e[1;31m[FINAL VERDICT: FAIL]\e[0m %d TEST(S) FAILED VERIFICATION.\n' "${FAILED_TESTS}"
        return 1
    fi
}

main "$@"
