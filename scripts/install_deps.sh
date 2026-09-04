#!/usr/bin/env bash
# ==============================================================================
# IPTV MULTICAST LAB - DEPENDENCY INSTALLATION SCRIPT
# Installs required host packages (FFmpeg, VLC, dnsmasq, udhcpc, tcpdump, etc.)
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

readonly REQUIRED_PACKAGES=(
    ca-certificates
    dnsmasq
    ethtool
    ffmpeg
    iproute2
    iputils-ping
    procps
    python3
    tcpdump
    tshark
    udhcpc
    vlc
)

main() {
    if [[ "$(id -u)" -ne 0 ]]; then
        printf 'ERROR: This script must be run as root (or with sudo).\n' >&2
        printf 'Usage: sudo ./scripts/install_deps.sh\n' >&2
        exit 1
    fi

    printf '==============================================================================\n'
    printf '        IPTV MULTICAST TEST LAB - HOST DEPENDENCY INSTALLER                    \n'
    printf '==============================================================================\n\n'

    if command -v apt-get >/dev/null 2>&1; then
        printf 'Detected Debian/Ubuntu APT package manager.\n'
        printf 'Updating package indices...\n'
        apt-get update -y

        printf 'Installing required packages: %s...\n' "${REQUIRED_PACKAGES[*]}"
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${REQUIRED_PACKAGES[@]}"

        printf '\nAll dependencies installed successfully!\n'
    elif command -v dnf >/dev/null 2>&1; then
        printf 'Detected Fedora/RHEL DNF package manager.\n'
        dnf install -y ffmpeg vlc udhcpc-script dnsmasq tcpdump wireshark-cli python3 iproute
        printf '\nAll dependencies installed successfully!\n'
    else
        printf 'WARNING: Unsupported package manager. Please manually install:\n'
        printf '  %s\n' "${REQUIRED_PACKAGES[*]}"
        exit 1
    fi

    printf '==============================================================================\n'
    printf 'You are ready to run the lab without Docker!\n'
    printf '==============================================================================\n'
}

main "$@"
