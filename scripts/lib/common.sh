#!/usr/bin/env bash
# ==============================================================================
# REAL IPTV MULTICAST TEST LAB - COMMON LIBRARY
# Standard framework helpers: logging, lifecycle, interface safety, docker, netns
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${LIB_DIR}/../.." && pwd)"

# Standard ANSI loggers
log_info()  { printf '\e[1;32m[INFO]\e[0m  %s\n' "$*"; }
log_warn()  { printf '\e[1;33m[WARN]\e[0m  %s\n' "$*"; }
log_error() { printf '\e[1;31m[ERROR]\e[0m %s\n' "$*" >&2; }
die()       { log_error "$*"; exit 1; }

require_root() {
    [[ ${EUID} -eq 0 ]] || die "This script requires root privileges. Please run with sudo."
}

require_cmd() {
    local cmd="$1"
    command -v "${cmd}" >/dev/null 2>&1 || die "Missing required command: ${cmd}"
}

load_config() {
    local config_file="${1:-${PROJECT_ROOT}/config.env}"

    if [[ ! -f "${config_file}" ]]; then
        if [[ -f "${PROJECT_ROOT}/config.env.example" ]]; then
            log_warn "config.env not found. Copying from config.env.example..."
            cp "${PROJECT_ROOT}/config.env.example" "${config_file}"
        else
            die "Missing configuration file: ${config_file}"
        fi
    fi

    # shellcheck disable=SC1090
    source "${config_file}"

    # Set defaults for optional parameters
    : "${IS_VIRTUAL:=0}"
    : "${SERVER_ONLY:=0}"
    : "${WAN_BRIDGE:=br-test-wan}"
    : "${LAN_BRIDGE:=br-test-lan}"
    : "${WAN_NS:=ns-wan}"
    : "${WAN_NS_IP:=10.10.0.254/24}"
    : "${WAN_NS_GW:=10.10.0.1}"
    : "${DUT_WAN_IP:=10.10.0.1}"
    : "${DUT_LAN_IP:=10.20.0.1}"
    : "${ENABLE_WAN_DHCP:=1}"
    : "${WAN_DHCP_START:=10.10.0.1}"
    : "${WAN_DHCP_END:=10.10.0.50}"
    : "${WAN_DHCP_LEASE:=12h}"
    : "${MEDIA_IMAGE:=multicast-media-tools:latest}"
    : "${MEDIA_FILE:=sample_1080p_8mbps.ts}"
    : "${MEDIA_DIR:=./media}"
    : "${MCAST_GROUP:=239.10.10.10}"
    : "${MCAST_PORT:=5000}"
    : "${MCAST_TTL:=16}"
    : "${MPEGTS_PKT_SIZE:=1316}"
    : "${STREAM_BITRATE:=8M}"
    : "${SERVER_NAME:=mcast-server}"
    : "${SERVER_IP:=10.10.0.2/24}"
    : "${SERVER_GW:=10.10.0.1}"
    : "${CLIENT1_NAME:=mcast-client1}"
    : "${CLIENT1_IP:=10.20.0.11/24}"
    : "${CLIENT1_GW:=10.20.0.1}"
    : "${CLIENT1_HOSTNAME:=stb-living-room}"
    : "${CLIENT2_NAME:=mcast-client2}"
    : "${CLIENT2_IP:=10.20.0.12/24}"
    : "${CLIENT2_GW:=10.20.0.1}"
    : "${CLIENT2_HOSTNAME:=stb-bedroom}"
    : "${CLIENT_DHCP_VENDOR:=IPTV_STB}"
    : "${FORCE_IGMP_VERSION:=2}"
    : "${CAPTURE_DIR:=captures}"
    : "${LOG_DIR:=logs}"
    : "${STATE_DIR:=state}"
    : "${CAPTURE_FILTER:=igmp or (udp and port 5000)}"

    # Resolve relative paths to absolute paths
    if [[ "${CAPTURE_DIR}" != /* ]]; then CAPTURE_DIR="${PROJECT_ROOT}/${CAPTURE_DIR}"; fi
    if [[ "${LOG_DIR}" != /* ]]; then LOG_DIR="${PROJECT_ROOT}/${LOG_DIR}"; fi
    if [[ "${STATE_DIR}" != /* ]]; then STATE_DIR="${PROJECT_ROOT}/${STATE_DIR}"; fi
    if [[ "${MEDIA_DIR}" != /* ]]; then MEDIA_DIR="${PROJECT_ROOT}/${MEDIA_DIR#./}"; fi

    ensure_runtime_dirs
}

ensure_runtime_dirs() {
    install -d -m 0777 "${CAPTURE_DIR}" "${LOG_DIR}" "${STATE_DIR}" "${MEDIA_DIR}"
    chmod 0777 "${CAPTURE_DIR}" "${LOG_DIR}" "${STATE_DIR}" "${MEDIA_DIR}" 2>/dev/null || true
    chmod -R a+rw "${CAPTURE_DIR}" "${LOG_DIR}" "${STATE_DIR}" 2>/dev/null || true
}

is_pidfile_running() {
    local pidfile="$1"
    local pid=""

    [[ -f "${pidfile}" ]] || return 1
    pid="$(cat "${pidfile}" 2>/dev/null || true)"
    [[ -n "${pid}" && "${pid}" =~ ^[0-9]+$ ]] || return 1
    kill -0 "${pid}" 2>/dev/null || [[ -d "/proc/${pid}" ]]
}

stop_pidfile() {
    local pidfile="$1"
    local pid=""
    local attempt

    [[ -f "${pidfile}" ]] || return 0
    pid="$(cat "${pidfile}" 2>/dev/null || true)"

    if [[ "${pid}" =~ ^[0-9]+$ ]] && kill -0 "${pid}" 2>/dev/null; then
        kill -INT "${pid}" 2>/dev/null || true
        for attempt in {1..10}; do
            kill -0 "${pid}" 2>/dev/null || break
            sleep 0.1
        done
        if kill -0 "${pid}" 2>/dev/null; then
            kill -TERM "${pid}" 2>/dev/null || true
        fi
        for attempt in {1..10}; do
            kill -0 "${pid}" 2>/dev/null || break
            sleep 0.1
        done
        if kill -0 "${pid}" 2>/dev/null; then
            kill -KILL "${pid}" 2>/dev/null || true
        fi
    fi
    rm -f "${pidfile}"
}

iface_exists_root() {
    local iface="$1"
    ip link show dev "${iface}" >/dev/null 2>&1
}

iface_exists_ns() {
    local ns="$1"
    local iface="$2"
    ip netns exec "${ns}" ip link show dev "${iface}" >/dev/null 2>&1
}

ns_exists() {
    local ns="$1"
    ip netns list 2>/dev/null | awk '{print $1}' | grep -Fxq "${ns}"
}

bridge_exists() {
    local bridge="$1"
    ip link show dev "${bridge}" >/dev/null 2>&1
}

assert_safe_test_if() {
    local iface="$1"

    [[ -n "${iface}" ]] || die "Interface name cannot be empty."
    [[ "${iface}" != "lo" ]] || die "Refusing to use loopback interface."
    iface_exists_root "${iface}" || die "Interface not found in root namespace: ${iface}"

    # Protect host default route
    if ip route show default 2>/dev/null | grep -Eq "dev[[:space:]]+${iface}([[:space:]]|$)"; then
        die "Interface ${iface} carries host default route! Use a dedicated Ethernet adapter."
    fi

    # Smart NetworkManager unmanage & flush
    if ip -4 addr show dev "${iface}" 2>/dev/null | grep -q 'inet '; then
        log_warn "Interface ${iface} has host IPv4 address. Flushing and setting unmanaged..."
        command -v nmcli >/dev/null 2>&1 && nmcli device set "${iface}" managed no 2>/dev/null || true
        ip addr flush dev "${iface}" 2>/dev/null || true
    fi
}

bridge_create() {
    local bridge="$1"
    if ! bridge_exists "${bridge}"; then
        ip link add name "${bridge}" type bridge
    fi
    ip addr flush dev "${bridge}" 2>/dev/null || true
    ip link set dev "${bridge}" type bridge stp_state 0 mcast_snooping 0 2>/dev/null || true
    ip link set dev "${bridge}" up
}

attach_physical_to_bridge() {
    local iface="$1"
    local bridge="$2"

    assert_safe_test_if "${iface}"
    command -v nmcli >/dev/null 2>&1 && nmcli device set "${iface}" managed no 2>/dev/null || true
    ip link set dev "${iface}" down
    ip addr flush dev "${iface}" 2>/dev/null || true
    ip link set dev "${iface}" master "${bridge}"
    ip link set dev "${iface}" up
}

cleanup_bridge_and_nic() {
    local bridge="$1"
    local iface="${2:-}"

    if [[ -n "${iface}" ]] && iface_exists_root "${iface}"; then
        ip link set dev "${iface}" nomaster 2>/dev/null || true
        ip addr flush dev "${iface}" 2>/dev/null || true
        ip link set dev "${iface}" down 2>/dev/null || true
    fi

    if bridge_exists "${bridge}"; then
        ip link set dev "${bridge}" down 2>/dev/null || true
        ip link del dev "${bridge}" 2>/dev/null || true
    fi
}

# ------------------------------------------------------------------------------
# Docker Container Helpers
# ------------------------------------------------------------------------------
check_docker() {
    require_cmd docker
    docker info >/dev/null 2>&1 || die "Docker daemon is not running or current user lacks access."
}

container_exists() {
    local name="$1"
    docker inspect "${name}" >/dev/null 2>&1
}

container_pid() {
    local name="$1"
    docker inspect -f '{{.State.Pid}}' "${name}" 2>/dev/null || true
}

start_idle_container() {
    local name="$1"
    if container_exists "${name}"; then
        docker rm -f "${name}" >/dev/null 2>&1 || true
    fi

    check_docker
    docker run -d --rm --network none \
        --name "${name}" \
        -v "${MEDIA_DIR}:/media:ro" \
        "${MEDIA_IMAGE}" -lc 'exec sleep infinity' >/dev/null
}

attach_container_to_bridge() {
    local name="$1"
    local bridge="$2"
    local host_veth="$3"
    local peer_veth="$4"
    local cidr="$5"
    local gateway="$6"
    local hostname="${7:-}"
    local pid

    pid="$(container_pid "${name}")"
    [[ -n "${pid}" && "${pid}" -gt 0 ]] || die "Could not get PID for container ${name}"

    ip link del "${host_veth}" 2>/dev/null || true
    ip link add "${host_veth}" type veth peer name "${peer_veth}"
    ip link set "${host_veth}" master "${bridge}"
    ip link set "${host_veth}" up
    ip link set "${peer_veth}" netns "${pid}"

    nsenter -t "${pid}" -n ip link set lo up
    nsenter -t "${pid}" -n ip link set "${peer_veth}" name eth0
    nsenter -t "${pid}" -n ip addr flush dev eth0 2>/dev/null || true
    if [[ -n "${cidr}" ]]; then
        nsenter -t "${pid}" -n ip addr add "${cidr}" dev eth0
    fi
    nsenter -t "${pid}" -n ip link set eth0 up
    if [[ -n "${gateway}" ]]; then
        nsenter -t "${pid}" -n ip route replace default via "${gateway}" dev eth0
    fi

    if [[ -n "${hostname}" ]]; then
        nsenter -t "${pid}" -u hostname "${hostname}" 2>/dev/null || true
        printf '%s\n' "${hostname}" > "${STATE_DIR}/hostname-${name}.txt"
    fi
}

force_container_igmp_version() {
    local name="$1"
    local version="$2"
    local pid
    pid="$(container_pid "${name}")"
    [[ -n "${pid}" && "${pid}" -gt 0 ]] || return 0
    nsenter -t "${pid}" -n sysctl -q -w "net.ipv4.conf.all.force_igmp_version=${version}" 2>/dev/null || true
    nsenter -t "${pid}" -n sysctl -q -w "net.ipv4.conf.eth0.force_igmp_version=${version}" 2>/dev/null || true
}

# ------------------------------------------------------------------------------
# Virtual DUT Simulation
# ------------------------------------------------------------------------------
setup_virtual_dut() {
    local ns_dut="ns-dut"
    log_info "Creating simulated DUT router ${ns_dut}..."

    if ! ns_exists "${ns_dut}"; then
        ip netns add "${ns_dut}"
    fi
    ip -n "${ns_dut}" link set lo up

    # Create veth to WAN bridge
    ip link del dev v-dut-wan-h 2>/dev/null || true
    ip link add v-dut-wan-h type veth peer name dut-wan netns "${ns_dut}"
    ip link set v-dut-wan-h master "${WAN_BRIDGE}"
    ip link set v-dut-wan-h up
    ip -n "${ns_dut}" link set dut-wan up

    # Create veth to LAN bridge
    ip link del dev v-dut-lan-h 2>/dev/null || true
    ip link add v-dut-lan-h type veth peer name dut-lan netns "${ns_dut}"
    ip link set v-dut-lan-h master "${LAN_BRIDGE}"
    ip link set v-dut-lan-h up
    ip -n "${ns_dut}" link set dut-lan up

    # Bridge WAN and LAN inside ns-dut for multicast forwarding without extra daemons
    ip netns exec "${ns_dut}" ip link del br-dut 2>/dev/null || true
    ip netns exec "${ns_dut}" ip link add name br-dut type bridge
    ip netns exec "${ns_dut}" ip link set dev br-dut type bridge stp_state 0 mcast_snooping 0 2>/dev/null || true
    ip netns exec "${ns_dut}" ip link set dut-wan master br-dut
    ip netns exec "${ns_dut}" ip link set dut-lan master br-dut
    ip netns exec "${ns_dut}" ip addr add "${DUT_WAN_IP}/24" dev br-dut
    ip netns exec "${ns_dut}" ip addr add "${DUT_LAN_IP}/24" dev br-dut
    ip netns exec "${ns_dut}" ip link set br-dut up

    # Enable multicast forwarding inside simulated DUT
    ip netns exec "${ns_dut}" sysctl -q -w net.ipv4.ip_forward=1 2>/dev/null || true
    ip netns exec "${ns_dut}" sysctl -q -w net.ipv4.conf.all.mc_forwarding=1 2>/dev/null || true
    ip netns exec "${ns_dut}" sysctl -q -w net.ipv4.conf.br-dut.force_igmp_version=2 2>/dev/null || true

    log_info "Simulated DUT ready: Bridged WAN (${DUT_WAN_IP}) & LAN (${DUT_LAN_IP}) with multicast forwarding"
}

# ------------------------------------------------------------------------------
# WAN DHCP Server Management (inside ns-wan)
# ------------------------------------------------------------------------------
wan_dhcp_server() {
    local action="$1"
    local pidfile="${STATE_DIR}/dnsmasq-wan.pid"
    local conffile="${STATE_DIR}/dnsmasq-wan.conf"
    local leasefile="${STATE_DIR}/dnsmasq-wan.leases"
    local logfile="${LOG_DIR}/dnsmasq-wan.log"

    case "${action}" in
        start)
            require_root
            require_cmd dnsmasq
            stop_pidfile "${pidfile}"

            cat >"${conffile}" <<EOF
port=0
no-resolv
no-hosts
bind-interfaces
interface=eth0
dhcp-range=${WAN_DHCP_START},${WAN_DHCP_END},255.255.255.0,${WAN_DHCP_LEASE}
dhcp-option=option:router,${WAN_NS_IP%/*}
dhcp-option=option:dns-server,${WAN_NS_IP%/*}
dhcp-authoritative
dhcp-leasefile=${leasefile}
log-facility=${logfile}
log-dhcp
EOF
            if [[ -n "${DUT_WAN_MAC:-}" ]]; then
                printf 'dhcp-host=%s,%s\n' "${DUT_WAN_MAC}" "${DUT_WAN_IP}" >>"${conffile}"
            fi

            touch "${leasefile}"
            chmod 0666 "${leasefile}" 2>/dev/null || true

            ip netns exec "${WAN_NS}" dnsmasq --conf-file="${conffile}" --pid-file="${pidfile}"
            log_info "WAN DHCP Server (dnsmasq) started in ${WAN_NS} [PID $(cat "${pidfile}" 2>/dev/null || echo '?')]"
            ;;

        stop)
            stop_pidfile "${pidfile}"
            log_info "WAN DHCP Server stopped."
            ;;

        status)
            if is_pidfile_running "${pidfile}"; then
                printf 'WAN DHCP Server: RUNNING (PID %s in %s)\n' "$(cat "${pidfile}")" "${WAN_NS}"
                if [[ -f "${leasefile}" && -s "${leasefile}" ]]; then
                    printf '== Active WAN DHCP Leases ==\n'
                    cat "${leasefile}"
                else
                    printf '<No active WAN leases recorded yet>\n'
                fi
            else
                printf 'WAN DHCP Server: STOPPED\n'
            fi
            ;;
    esac
}

namespace_ip() {
    local ns="${1:-${WAN_NS}}"
    local iface="${2:-eth0}"
    ip netns exec "${ns}" ip -4 -o addr show dev "${iface}" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1
}

# ------------------------------------------------------------------------------
# Direct Standalone WAN Server & DHCP Helpers (Host-level, no Docker bridge)
# ------------------------------------------------------------------------------
configure_direct_wan_interface() {
    local iface="$1"
    local cidr="$2"

    require_root
    assert_safe_test_if "${iface}"

    # Detach iface if it is slaved to any bridge
    if ip link show dev "${iface}" 2>/dev/null | grep -q "master"; then
        log_info "Detaching ${iface} from bridge master..."
        ip link set dev "${iface}" nomaster 2>/dev/null || true
    fi

    # NetworkManager unmanage
    command -v nmcli >/dev/null 2>&1 && nmcli device set "${iface}" managed no 2>/dev/null || true

    ip link set dev "${iface}" up

    # Configure IP
    if ! ip -4 addr show dev "${iface}" 2>/dev/null | grep -q "${cidr}"; then
        ip addr flush dev "${iface}" 2>/dev/null || true
        ip addr add "${cidr}" dev "${iface}"
    fi

    # Multicast route: Ensure multicast traffic goes out WAN_IF
    ip route replace 224.0.0.0/4 dev "${iface}"

    # Force IGMPv2 on physical interface if writable
    if [[ -w "/proc/sys/net/ipv4/conf/${iface}/force_igmp_version" ]]; then
        printf '2\n' > "/proc/sys/net/ipv4/conf/${iface}/force_igmp_version" 2>/dev/null || true
    fi

    log_info "Interface ${iface} configured for direct WAN IPTV streaming (${cidr})."
}

restore_physical_interface() {
    local iface="$1"
    require_root

    [[ -n "${iface}" ]] || return 0
    iface_exists_root "${iface}" || return 0

    log_info "Restoring interface ${iface} to UP state with DHCP..."

    # 1. Detach from bridge master if any
    ip link set dev "${iface}" nomaster 2>/dev/null || true

    # 2. Delete test multicast route
    if ip route show 224.0.0.0/4 2>/dev/null | grep -Eq "dev[[:space:]]+${iface}([[:space:]]|$)"; then
        ip route del 224.0.0.0/4 dev "${iface}" 2>/dev/null || true
    fi

    # 3. Flush any static lab IP
    ip addr flush dev "${iface}" 2>/dev/null || true

    # 4. Bring interface link UP
    ip link set dev "${iface}" up

    # 5. Hand over to NetworkManager and trigger auto-connect
    if command -v nmcli >/dev/null 2>&1; then
        nmcli device set "${iface}" managed yes 2>/dev/null || true
        nmcli device set "${iface}" autoconnect yes 2>/dev/null || true
        nmcli device connect "${iface}" >/dev/null 2>&1 || true
    fi

    # 6. Fallback DHCP if carrier is present
    if ip link show dev "${iface}" 2>/dev/null | grep -q "LOWER_UP"; then
        local got_ip=0
        for (( i=0; i<4; i++ )); do
            if ip -4 -o addr show dev "${iface}" 2>/dev/null | grep -q 'inet '; then
                got_ip=1
                break
            fi
            sleep 0.5
        done

        if (( got_ip == 0 )) && command -v dhclient >/dev/null 2>&1; then
            log_info "Triggering dhclient for ${iface}..."
            dhclient -4 -nw "${iface}" 2>/dev/null || true
        fi
    fi

    local current_ip
    current_ip="$(ip -4 -o addr show dev "${iface}" 2>/dev/null | awk '{print $4}' | head -n1 || echo '')"
    if [[ -n "${current_ip}" ]]; then
        log_info "Interface ${iface} is UP with IP: ${current_ip}"
    else
        log_info "Interface ${iface} is UP [Managed]. Waiting for DHCP lease from network."
    fi
}

tear_down_physical_interface() {
    local iface="$1"
    require_root

    [[ -n "${iface}" ]] || return 0
    iface_exists_root "${iface}" || return 0

    if ip route show 224.0.0.0/4 2>/dev/null | grep -Eq "dev[[:space:]]+${iface}([[:space:]]|$)"; then
        ip route del 224.0.0.0/4 dev "${iface}" 2>/dev/null || true
    fi
    if command -v dhclient >/dev/null 2>&1; then
        dhclient -x "${iface}" 2>/dev/null || true
    fi
    ip link set dev "${iface}" nomaster 2>/dev/null || true
    ip addr flush dev "${iface}" 2>/dev/null || true
    ip link set dev "${iface}" down 2>/dev/null || true
    command -v nmcli >/dev/null 2>&1 && nmcli device set "${iface}" managed yes 2>/dev/null || true
    log_info "Interface ${iface} is DOWN and flushed."
}

cleanup_direct_wan_interface() {
    local iface="$1"
    local restore="${2:-${RESTORE_INTERFACES_ON_CLEANUP:-1}}"
    require_root

    if [[ -n "${iface}" ]] && iface_exists_root "${iface}"; then
        if (( restore == 1 )); then
            restore_physical_interface "${iface}"
        else
            tear_down_physical_interface "${iface}"
        fi
    fi
}

direct_wan_dhcp_server() {
    local action="$1"
    local iface="${2:-${WAN_IF}}"
    local pidfile="${STATE_DIR}/dnsmasq-direct.pid"
    local conffile="${STATE_DIR}/dnsmasq-direct.conf"
    local leasefile="${STATE_DIR}/dnsmasq-direct.leases"
    local logfile="${LOG_DIR}/dnsmasq-direct.log"

    case "${action}" in
        start)
            require_root
            require_cmd dnsmasq
            stop_pidfile "${pidfile}"

            cat >"${conffile}" <<EOF
port=0
no-resolv
no-hosts
bind-interfaces
interface=${iface}
dhcp-range=${WAN_DHCP_START},${WAN_DHCP_END},255.255.255.0,${WAN_DHCP_LEASE}
dhcp-option=option:router,${SERVER_IP%/*}
dhcp-option=option:dns-server,${SERVER_IP%/*}
dhcp-authoritative
dhcp-leasefile=${leasefile}
log-facility=${logfile}
log-dhcp
EOF
            if [[ -n "${DUT_WAN_MAC:-}" ]]; then
                printf 'dhcp-host=%s,%s\n' "${DUT_WAN_MAC}" "${DUT_WAN_IP}" >>"${conffile}"
            fi

            touch "${leasefile}"
            chmod 0666 "${leasefile}" 2>/dev/null || true

            dnsmasq --conf-file="${conffile}" --pid-file="${pidfile}"
            log_info "Direct WAN DHCP Server (dnsmasq) started on ${iface} [PID $(cat "${pidfile}" 2>/dev/null || echo '?')]"
            ;;

        stop)
            stop_pidfile "${pidfile}"
            rm -f "${conffile}" 2>/dev/null || true
            log_info "Direct WAN DHCP Server stopped."
            ;;

        status)
            if is_pidfile_running "${pidfile}"; then
                printf 'Direct WAN DHCP Server: RUNNING (PID %s on %s)\n' "$(cat "${pidfile}")" "${iface}"
                if [[ -f "${leasefile}" && -s "${leasefile}" ]]; then
                    printf '== Active Direct WAN DHCP Leases ==\n'
                    cat "${leasefile}"
                else
                    printf '<No active direct WAN leases recorded yet>\n'
                fi
            else
                printf 'Direct WAN DHCP Server: STOPPED\n'
            fi
            ;;
    esac
}

