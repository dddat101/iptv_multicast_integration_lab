#!/usr/bin/env bash
# ==============================================================================
# REAL IPTV MULTICAST TEST LAB - AUTOMATED PCAP VERIFICATION
# Verifies real IGMPv2 Join/Leave signaling and MPEG-TS multicast data flow
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
    cat <<'USAGE'
Usage:
  ./scripts/verify_capture.sh [summary|latency|full] [pcap_file]
USAGE
}

resolve_pcap() {
    local candidate="${1:-}"

    if [[ -n "${candidate}" && -f "${candidate}" ]]; then
        printf '%s\n' "${candidate}"
        return 0
    fi

    if [[ -f "${STATE_DIR}/latest_capture.txt" ]]; then
        candidate="$(cat "${STATE_DIR}/latest_capture.txt")"
        if [[ -f "${candidate}" ]]; then
            printf '%s\n' "${candidate}"
            return 0
        fi
    fi

    local newest
    newest="$(ls -t "${CAPTURE_DIR}"/*.pcap* 2>/dev/null | head -n1 || true)"
    if [[ -n "${newest}" && -f "${newest}" ]]; then
        printf '%s\n' "${newest}"
        return 0
    fi

    die "No capture file found in ${CAPTURE_DIR}."
}

calculate_latency() {
    local pcap="$1"
    local group="${2:-${MCAST_GROUP}}"

    local t_join t_data latency_sec latency_ms

    t_join="$((tshark -r "${pcap}" -Y "igmp.type == 0x16 && igmp.maddr == ${group}" -T fields -e frame.time_epoch 2>/dev/null || true) | head -n1)"
    t_data="$((tshark -r "${pcap}" -Y "ip.dst == ${group} && udp.dstport == ${MCAST_PORT}" -T fields -e frame.time_epoch 2>/dev/null || true) | awk -v j="${t_join}" 'j == "" || $1 >= j {print $1; exit}')"

    if [[ -z "${t_join}" ]]; then
        printf 'ERROR: No IGMP Join found for group %s\n' "${group}" >&2
        return 1
    fi

    if [[ -z "${t_data}" ]]; then
        printf 'ERROR: No Multicast UDP data packets found for group %s\n' "${group}" >&2
        return 1
    fi

    latency_sec="$(awk -v d="${t_data}" -v j="${t_join}" 'BEGIN { printf "%.6f", d - j }')"
    latency_ms="$(awk -v d="${t_data}" -v j="${t_join}" 'BEGIN { printf "%.3f", (d - j) * 1000 }')"

    printf 't_join_epoch=%s\n' "${t_join}"
    printf 't_first_data_epoch=%s\n' "${t_data}"
    printf 'join_to_first_data_sec=%s\n' "${latency_sec}"
    printf 'join_to_first_data_ms=%s\n' "${latency_ms}"
}

verify_full() {
    local pcap="$1"
    local group="${2:-${MCAST_GROUP}}"

    require_cmd tshark

    log_info "Analyzing PCAP verification evidence: ${pcap}"

    # 1. Check IGMPv2 Report (Join)
    local join_count
    join_count="$((tshark -r "${pcap}" -Y "igmp.type == 0x16 && igmp.maddr == ${group}" 2>/dev/null || true) | wc -l)"

    # 2. Check MPEG-TS Multicast Data Packets
    local data_count
    data_count="$((tshark -r "${pcap}" -Y "ip.dst == ${group} && udp.dstport == ${MCAST_PORT}" 2>/dev/null || true) | wc -l)"

    # 3. Check Join-to-first-data Latency
    local latency_ms="N/A"
    local latency_res="FAIL"
    if (( join_count > 0 && data_count > 0 )); then
        local t_join t_data
        t_join="$((tshark -r "${pcap}" -Y "igmp.type == 0x16 && igmp.maddr == ${group}" -T fields -e frame.time_epoch 2>/dev/null || true) | head -n1)"
        t_data="$((tshark -r "${pcap}" -Y "ip.dst == ${group} && udp.dstport == ${MCAST_PORT}" -T fields -e frame.time_epoch 2>/dev/null || true) | awk -v j="${t_join}" 'j == "" || $1 >= j {print $1; exit}')"
        if [[ -n "${t_join}" && -n "${t_data}" ]]; then
            latency_ms="$(awk -v d="${t_data}" -v j="${t_join}" 'BEGIN { printf "%.3f", (d - j) * 1000 }')"
            latency_res="$(awk -v l="${latency_ms}" 'BEGIN { if (l <= 10.0) print "PASS (<=10ms)"; else print "INFO (>10ms)" }')"
        fi
    fi

    # 4. Check IGMP Leave Group
    local leave_count
    leave_count="$((tshark -r "${pcap}" -Y "igmp.type == 0x17 && igmp.maddr == ${group}" 2>/dev/null || true) | wc -l)"

    # 5. Check IGMP ToS / DSCP and DF bit
    local igmp_tos igmp_df r15_res
    igmp_tos="$((tshark -r "${pcap}" -Y "igmp" -T fields -e ip.tos 2>/dev/null || true) | sort -u | tr '\n' ',' | sed 's/,$//')"
    igmp_df="$((tshark -r "${pcap}" -Y "igmp" -T fields -e ip.flags.df 2>/dev/null || true) | sort -u | tr '\n' ',' | sed 's/,$//')"
    if [[ -z "${igmp_tos}" ]]; then
        igmp_tos="N/A"
        r15_res="N/A"
    else
        r15_res="RECORDED (${igmp_tos})"
    fi

    # 6. Check Source IP and MAC
    local igmp_src_ips igmp_src_macs
    igmp_src_ips="$((tshark -r "${pcap}" -Y "igmp" -T fields -e ip.src 2>/dev/null || true) | sort -u | tr '\n' ' ')"
    igmp_src_macs="$((tshark -r "${pcap}" -Y "igmp" -T fields -e eth.src 2>/dev/null || true) | sort -u | tr '\n' ' ')"

    printf '\n==============================================================================\n'
    printf '                 IPTV MULTICAST LAB - VERIFICATION REPORT                      \n'
    printf '==============================================================================\n'
    printf 'Capture File:     %s\n' "${pcap}"
    printf 'Multicast Group:  %s (UDP Port %s)\n' "${group}" "${MCAST_PORT}"
    printf '%s\n' '------------------------------------------------------------------------------'
    printf '  %-38s | %-16s | %-12s\n' "Metric / Protocol Check" "Observed" "Result"
    printf '%s\n' '------------------------------------------------------------------------------'
    printf '  %-38s | %-16s | %-12s\n' "IGMP Membership Reports (Join)" "${join_count}" "$([[ ${join_count} -gt 0 ]] && echo 'PASS' || echo 'FAIL')"
    printf '  %-38s | %-16s | %-12s\n' "MPEG-TS Multicast Data Packets" "${data_count}" "$([[ ${data_count} -gt 0 ]] && echo 'PASS' || echo 'FAIL')"
    printf '  %-38s | %-16s | %-12s\n' "Join-to-First-Data Latency" "${latency_ms} ms" "${latency_res}"
    printf '  %-38s | %-16s | %-12s\n' "IGMP Leave Messages" "${leave_count}" "$([[ ${leave_count} -gt 0 ]] && echo 'PASS' || echo 'INFO')"
    printf '  %-38s | %-16s | %-12s\n' "IGMP IPv4 ToS / DSCP Byte" "${igmp_tos}" "${r15_res}"
    printf '  %-38s | %-16s | %-12s\n' "IGMP IP DF Flag" "${igmp_df:-N/A}" "$([[ "${igmp_df:-}" == *"1"* ]] && echo 'DF=1' || echo 'DF=0')"
    printf '  %-38s | %-16s | %-12s\n' "IGMP Source IPs" "${igmp_src_ips:0:16}" "INSPECT"
    printf '==============================================================================\n'

    if (( join_count > 0 && data_count > 0 )); then
        printf 'FUNCTIONAL RESULT: PASS (Video streaming and IGMP signaling verified)\n'
        return 0
    else
        printf 'FUNCTIONAL RESULT: FAIL (Missing join or multicast packets)\n'
        return 1
    fi
}


main() {
    load_config
    local mode="${1:-full}"
    local pcap_arg="${2:-}"
    local pcap_file

    pcap_file="$(resolve_pcap "${pcap_arg}")"

    case "${mode}" in
        summary|full|compliance)
            verify_full "${pcap_file}"
            ;;
        latency)
            calculate_latency "${pcap_file}"
            ;;
        *)
            usage
            exit 2
            ;;
    esac
}

main "$@"

