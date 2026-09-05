#!/usr/bin/env bash
# ==============================================================================
# ROUTER / DUT MULTICAST DIAGNOSTIC COLLECTOR
# Collects Linux multicast routing, IGMP snooping, bridge MDB, and interface status
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

DUT_COMMANDS=(
    "ip -details addr show"
    "ip -details link show"
    "ip route show"
    "ip mroute show"
    "bridge mdb show"
    "cat /proc/net/igmp"
    "cat /proc/net/ip_mr_vif"
    "cat /proc/net/ip_mr_mfc"
    "cat /proc/sys/net/ipv4/igmp_max_memberships"
    "cat /proc/sys/net/ipv4/igmp_max_msf"
    "cat /proc/sys/net/ipv4/conf/all/force_igmp_version"
    "cat /proc/sys/net/ipv4/conf/all/mc_forwarding"
    "dmesg | tail -n 50"
)

usage() {
    cat <<'USAGE'
Usage:
  ./scripts/dut_collector.sh [collect|print-cmds|parse <logfile>]

Commands:
  collect      Connect to DUT via SSH and dump diagnostic evidence to logs/
  print-cmds   Print standard router diagnostic commands (for manual UART/Serial use)
  parse <file> Parse an existing diagnostic log to evaluate multicast and snooping state
USAGE
}

print_dut_commands() {
    printf '==============================================================================\n'
    printf '          ROUTER / DUT MULTICAST DIAGNOSTIC COMMANDS                          \n'
    printf '==============================================================================\n'
    for cmd in "${DUT_COMMANDS[@]}"; do
        printf '%s\n' "${cmd}"
    done
    if [[ -n "${DUT_CUSTOM_COMMANDS:-}" ]]; then
        printf '\n--- Custom / Driver Diagnostic Commands ---\n'
        printf '%s\n' "${DUT_CUSTOM_COMMANDS}"
    fi
    printf '==============================================================================\n'
}

run_dut_ssh() {
    local host="${DUT_SSH_HOST:-192.168.1.1}"
    local user="${DUT_SSH_USER:-admin}"
    local port="${DUT_SSH_PORT:-22}"
    local key="${DUT_SSH_KEY:-}"
    local pass="${DUT_SSH_PASS:-}"
    local logfile="$1"

    local -a ssh_cmd=("ssh" "-p" "${port}" "-o" "StrictHostKeyChecking=no" "-o" "UserKnownHostsFile=/dev/null" "-o" "ConnectTimeout=5")
    if [[ -n "${key}" && -f "${key}" ]]; then
        ssh_cmd+=("-i" "${key}")
    fi

    local target="${user}@${host}"

    log_info "Connecting to DUT at ${target}:${port}..."

    {
        printf '=== ROUTER MULTICAST DIAGNOSTIC COLLECTION: %s ===\n' "$(date '+%Y-%m-%d %H:%M:%S')"
        printf 'DUT Target: %s\n\n' "${target}"

        for cmd in "${DUT_COMMANDS[@]}"; do
            printf '%s\n' '----------------------------------------------------------------------'
            printf 'COMMAND: %s\n' "${cmd}"
            printf '%s\n' '----------------------------------------------------------------------'
            if command -v sshpass >/dev/null 2>&1 && [[ -n "${pass}" ]]; then
                sshpass -p "${pass}" "${ssh_cmd[@]}" "${target}" "${cmd}" 2>&1 || printf 'EXECUTION ERROR: %s\n' "${cmd}"
            else
                "${ssh_cmd[@]}" "${target}" "${cmd}" 2>&1 || printf 'EXECUTION ERROR: %s\n' "${cmd}"
            fi
            printf '\n'
        done

        if [[ -n "${DUT_CUSTOM_COMMANDS:-}" ]]; then
            while IFS= read -r custom_cmd; do
                [[ -n "${custom_cmd}" ]] || continue
                printf '%s\n' '----------------------------------------------------------------------'
                printf 'CUSTOM COMMAND: %s\n' "${custom_cmd}"
                printf '%s\n' '----------------------------------------------------------------------'
                if command -v sshpass >/dev/null 2>&1 && [[ -n "${pass}" ]]; then
                    sshpass -p "${pass}" "${ssh_cmd[@]}" "${target}" "${custom_cmd}" 2>&1 || printf 'EXECUTION ERROR: %s\n' "${custom_cmd}"
                else
                    "${ssh_cmd[@]}" "${target}" "${custom_cmd}" 2>&1 || printf 'EXECUTION ERROR: %s\n' "${custom_cmd}"
                fi
                printf '\n'
            done <<< "${DUT_CUSTOM_COMMANDS}"
        fi
    } | tee "${logfile}"

    log_info "Diagnostic evidence saved to: ${logfile}"
}

parse_dut_log() {
    local logfile="$1"
    [[ -f "${logfile}" ]] || die "Log file not found: ${logfile}"

    printf '\n==============================================================================\n'
    printf '            ROUTER MULTICAST DIAGNOSTIC SUMMARY: %s\n' "$(basename "${logfile}")"
    printf '==============================================================================\n'

    # 1. Multicast Routing (MFC)
    local mfc_entries
    mfc_entries="$(grep -A 5 "ip_mr_mfc" "${logfile}" | grep -v "Group" | head -n 5 || true)"
    if [[ -n "${mfc_entries}" ]]; then
        printf '  Multicast Forwarding Cache (MFC): ACTIVE\n'
    else
        printf '  Multicast Forwarding Cache (MFC): NONE RECORDED\n'
    fi

    # 2. Bridge MDB (Snooping)
    local mdb_entries
    mdb_entries="$(grep -A 5 "bridge mdb show" "${logfile}" | grep -v "COMMAND" | head -n 5 || true)"
    if [[ -n "${mdb_entries}" ]]; then
        printf '  Bridge Multicast DB (Snooping):   ACTIVE\n'
    else
        printf '  Bridge Multicast DB (Snooping):   NONE RECORDED\n'
    fi

    # 3. Kernel IGMP Limits
    local max_memberships
    max_memberships="$(grep -A 1 "igmp_max_memberships" "${logfile}" | tail -n 1 || true)"
    printf '  Kernel Max Memberships:           %s\n' "${max_memberships:-Not found}"

    printf '==============================================================================\n'
}

main() {
    load_config
    local action="${1:-collect}"

    case "${action}" in
        print-cmds)
            print_dut_commands
            ;;
        collect)
            mkdir -p "${LOG_DIR}"
            local ts
            ts="$(date '+%Y%m%d_%H%M%S')"
            local logfile="${LOG_DIR}/dut_diagnostics_${ts}.log"
            run_dut_ssh "${logfile}"
            parse_dut_log "${logfile}"
            ;;
        parse)
            local target_log="${2:-}"
            [[ -n "${target_log}" ]] || die "Usage: ./scripts/dut_collector.sh parse <logfile>"
            parse_dut_log "${target_log}"
            ;;
        *)
            usage
            exit 2
            ;;
    esac
}

main "$@"
