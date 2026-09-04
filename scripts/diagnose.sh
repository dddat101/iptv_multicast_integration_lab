#!/usr/bin/env bash
# ==============================================================================
# REAL IPTV MULTICAST TEST LAB - DIAGNOSTICS
# Non-destructive pre-flight check of host adapters, media, and tools
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

main() {
    load_config

    printf '==============================================================================\n'
    printf '                 REAL IPTV MULTICAST LAB - DIAGNOSTICS                        \n'
    printf '==============================================================================\n'

    printf '\n== Host Default Route (Must NOT be on test interfaces) ==\n'
    ip route show default 2>/dev/null || printf '<No default route found>\n'

    printf '\n== Physical Test Adapters ==\n'
    for ifname in "${WAN_IF:-}" "${LAN_IF:-}"; do
        [[ -n "${ifname}" ]] || continue
        printf '[Interface: %s]\n' "${ifname}"
        if iface_exists_root "${ifname}"; then
            local state carrier speed
            state="$(ip -br link show "${ifname}" | awk '{print $2}')"
            carrier="$(cat "/sys/class/net/${ifname}/carrier" 2>/dev/null || echo 'no carrier')"
            speed="$(ethtool "${ifname}" 2>/dev/null | grep -i 'Speed:' | awk '{print $2}' || echo 'N/A')"
            printf '  Link State:  %s (Carrier: %s, Speed: %s)\n' "${state}" "${carrier}" "${speed}"
            
            # Check if managed by NetworkManager
            if command -v nmcli >/dev/null 2>&1; then
                local nm_state
                nm_state="$(nmcli -t -f DEVICE,STATE device 2>/dev/null | grep "^${ifname}:" | cut -d: -f2 || echo 'unmanaged')"
                printf '  NM Status:   %s\n' "${nm_state}"
            fi
        else
            printf '  STATUS: NOT DETECTED (Check USB cable connection)\n'
        fi
    done

    printf '\n== Media Environment ==\n'
    if [[ -f "${MEDIA_DIR}/${MEDIA_FILE}" ]]; then
        printf '  Media Asset:   OK (%s, %s bytes)\n' "${MEDIA_FILE}" "$(stat -c %s "${MEDIA_DIR}/${MEDIA_FILE}" 2>/dev/null || echo '?')"
    else
        printf '  Media Asset:   MISSING (Run ./scripts/generate_media.sh)\n'
    fi

    printf '\n== Required Host Tools Availability ==\n'
    for cmd in ip bridge ffmpeg cvlc udhcpc dnsmasq tcpdump tshark python3 ethtool lsusb; do
        if command -v "${cmd}" >/dev/null 2>&1; then
            printf '  %-12s -> OK (%s)\n' "${cmd}" "$(command -v "${cmd}")"
        else
            printf '  %-12s -> MISSING (Install via sudo ./scripts/install_deps.sh)\n' "${cmd}"
        fi
    done

    printf '==============================================================================\n'
}

main "$@"
