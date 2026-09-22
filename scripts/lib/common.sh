#!/usr/bin/env bash
# ==============================================================================
# REAL IPTV MULTICAST TEST LAB - COMMON LIBRARY
# Standard framework helpers: logging, lifecycle, interface safety, netns
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${LIB_DIR}/../.." && pwd)"

# Standard ANSI loggers
log_info()    { printf '\e[1;32m[INFO]\e[0m    %s\n' "$*"; }
log_success() { printf '\e[1;32m[PASS]\e[0m    %s\n' "$*"; }
log_warn()    { printf '\e[1;33m[WARN]\e[0m    %s\n' "$*" >&2; }
log_error()   { printf '\e[1;31m[ERROR]\e[0m   %s\n' "$*" >&2; }
log_step()    { printf '\e[1;36m===> %s\e[0m\n' "$*"; }
die()         { log_error "$*"; exit 1; }

log_debug() {
    if [[ "${DEBUG:-0}" == "1" || "${VERBOSE:-0}" == "1" ]]; then
        printf '\e[1;34m[DEBUG]\e[0m   %s\n' "$*"
    fi
}

print_header() {
    local title="${1:-}"
    printf '==================================================================\n'
    if [[ -n "${title}" ]]; then
        printf '  %s\n' "${title}"
        printf '==================================================================\n'
    fi
}

print_section() {
    local section="$1"
    printf '\n--- [%s] ---\n' "${section}"
}

require_root() {
    [[ ${EUID} -eq 0 ]] || die "This script requires root privileges. Please run with sudo."
}

is_root() {
    [[ ${EUID} -eq 0 ]]
}

require_command() {
    local cmd="$1"
    command -v "${cmd}" >/dev/null 2>&1 || die "Missing required command: ${cmd}"
}

require_cmd() {
    require_command "$@"
}

check_command() {
    local cmd="$1"
    command -v "${cmd}" >/dev/null 2>&1
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
    : "${LAB_ROLE:=single}"
    : "${TOPOLOGY_MODE:=physical}"
    : "${IS_VIRTUAL:=0}"
    : "${SERVER_ONLY:=0}"
    : "${RESTORE_INTERFACES_ON_CLEANUP:=1}"
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
    : "${MEDIA_FILE:=sample_1080p_8mbps.ts}"
    : "${MEDIA_DIR:=./media}"
    : "${MCAST_GROUP:=239.10.10.10}"
    : "${MCAST_PORT:=5000}"
    : "${MCAST_TTL:=16}"
    : "${MPEGTS_PKT_SIZE:=1316}"
    : "${STREAM_BITRATE:=8M}"
    : "${SERVER_NAME:=ns-server}"
    : "${SERVER_IP:=10.10.0.2/24}"
    : "${SERVER_GW:=10.10.0.1}"
    : "${CLIENT_COUNT:=5}"
    : "${CLIENT_PREFIX:=ns-stb}"
    : "${CLIENT_HOSTNAME_PREFIX:=stb}"
    : "${CLIENT1_NAME:=ns-stb1}"
    : "${CLIENT1_IP:=10.20.0.11/24}"
    : "${CLIENT1_GW:=10.20.0.1}"
    : "${CLIENT1_HOSTNAME:=stb-living-room}"
    : "${CLIENT2_NAME:=ns-stb2}"
    : "${CLIENT2_IP:=10.20.0.12/24}"
    : "${CLIENT2_GW:=10.20.0.1}"
    : "${CLIENT2_HOSTNAME:=stb-bedroom}"
    : "${CLIENT_DHCP_VENDOR:=IPTV_STB}"
    : "${FORCE_IGMP_VERSION:=2}"
    : "${FORCE_MLD_VERSION:=2}"
    : "${IP_VERSION:=4}"
    : "${DUT_WAN_IP6:=fd00:10:10::1}"
    : "${DUT_LAN_IP6:=fd00:10:20::1}"
    : "${WAN_NS_IP6:=fd00:10:10::254/64}"
    : "${WAN_NS_GW6:=fd00:10:10::1}"
    : "${WAN_DHCP6_START:=fd00:10:10::10}"
    : "${WAN_DHCP6_END:=fd00:10:10::50}"
    : "${SERVER_IP6:=fd00:10:10::2/64}"
    : "${SERVER_GW6:=fd00:10:10::1}"
    : "${CLIENT1_IP6:=fd00:10:20::11/64}"
    : "${CLIENT1_GW6:=fd00:10:20::1}"
    : "${CLIENT2_IP6:=fd00:10:20::12/64}"
    : "${CLIENT2_GW6:=fd00:10:20::1}"
    : "${CLIENT_PREFIX_IP6:=fd00:10:20::}"
    : "${MCAST_GROUP6:=ff0e::10:10:10}"
    : "${CAPTURE_DIR:=captures}"
    : "${LOG_DIR:=logs}"
    : "${STATE_DIR:=state}"
    : "${CAPTURE_FILTER:=igmp or (udp and port 5000)}"
    : "${TCPDUMP_BIN:=tcpdump}"
    : "${TSHARK_BIN:=tshark}"

    # Auto-detect Python Virtualenv
    if [[ -z "${PYTHON_BIN:-}" ]]; then
        if [[ -x "${PROJECT_ROOT}/.venv/bin/python3" ]]; then
            PYTHON_BIN="${PROJECT_ROOT}/.venv/bin/python3"
        else
            PYTHON_BIN="python3"
        fi
    fi

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

clean_logs() {
    ensure_runtime_dirs
    log_info "Cleaning log files in ${LOG_DIR}..."
    find "${LOG_DIR}" -mindepth 1 ! -name '.gitkeep' -delete 2>/dev/null || true
    log_info "Logs directory cleaned."
}

clean_captures() {
    ensure_runtime_dirs
    log_info "Cleaning PCAP capture files in ${CAPTURE_DIR}..."
    find "${CAPTURE_DIR}" -mindepth 1 ! -name '.gitkeep' -delete 2>/dev/null || true
    rm -f "${STATE_DIR}/last_capture.env" "${STATE_DIR}/latest_capture.txt" 2>/dev/null || true
    log_info "Captures directory cleaned."
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
    local name="${2:-process}"
    local pid=""
    local attempt

    [[ -f "${pidfile}" ]] || return 0
    pid="$(cat "${pidfile}" 2>/dev/null || true)"

    if [[ "${pid}" =~ ^[0-9]+$ ]] && kill -0 "${pid}" 2>/dev/null; then
        kill -INT "${pid}" 2>/dev/null || true
        for attempt in {1..15}; do
            kill -0 "${pid}" 2>/dev/null || break
            sleep 0.1
        done
        if kill -0 "${pid}" 2>/dev/null; then
            kill -TERM "${pid}" 2>/dev/null || true
        fi
        for attempt in {1..15}; do
            kill -0 "${pid}" 2>/dev/null || break
            sleep 0.1
        done
        if kill -0 "${pid}" 2>/dev/null; then
            kill -KILL "${pid}" 2>/dev/null || true
        fi
    fi
    rm -f "${pidfile}"
}

start_daemon() {
    local pid_file="$1" log_file="$2" service_name="$3" exec_ns="${4:-}"
    shift 4 || true
    local cmd=("$@")

    if is_pidfile_running "${pid_file}"; then
        log_warn "${service_name} is already running (PID: $(cat "${pid_file}"))."
        return 0
    fi
    log_info "Starting ${service_name}..."
    local prefix=()
    if [[ -n "${exec_ns}" ]] && ns_exists "${exec_ns}"; then
        prefix=("ip" "netns" "exec" "${exec_ns}")
    fi
    "${prefix[@]}" nohup "${cmd[@]}" > "${log_file}" 2>&1 &
    local daemon_pid=$!
    echo "${daemon_pid}" > "${pid_file}"
    chmod 0666 "${pid_file}" "${log_file}" 2>/dev/null || true
    sleep 0.2
    if kill -0 "${daemon_pid}" 2>/dev/null; then
        log_info "${service_name} running (PID: ${daemon_pid}, Log: ${log_file})"
        return 0
    else
        log_error "Failed to start ${service_name}! Check log: ${log_file}"
        return 1
    fi
}

stop_process_by_pattern() {
    local pattern="$1" name="${2:-processes matching '${pattern}'}"
    if pgrep -f "${pattern}" >/dev/null 2>&1; then
        log_info "Terminating ${name}..."
        pkill -INT -f "${pattern}" 2>/dev/null || true
        sleep 0.3
        pgrep -f "${pattern}" >/dev/null 2>&1 && pkill -TERM -f "${pattern}" 2>/dev/null || true
        sleep 0.5
        pgrep -f "${pattern}" >/dev/null 2>&1 && pkill -9 -f "${pattern}" 2>/dev/null || true
    fi
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
    (ip netns list 2>/dev/null || true) | awk '{print $1}' | grep -Fxq "${ns}"
}

bridge_exists() {
    local bridge="$1"
    ip link show dev "${bridge}" >/dev/null 2>&1
}

require_test_if_present() {
    local iface="$1"
    iface_exists_root "${iface}" || die "Interface not found in root namespace: ${iface}"
}

assert_safe_test_if() {
    local iface="$1"

    [[ -n "${iface}" ]] || die "Interface name cannot be empty."
    [[ "${iface}" != "lo" ]] || die "Refusing to use loopback interface."
    iface_exists_root "${iface}" || die "Interface not found in root namespace: ${iface}"

    # Protect host default route
    if ip route show default 2>/dev/null | grep -Eq "dev[[:space:]]+${iface}([[:space:]]|$)"; then
        die "Interface ${iface} carries host default route! Cowardly refusing to disrupt host connectivity."
    fi

    # Smart NetworkManager unmanage
    command -v nmcli >/dev/null 2>&1 && nmcli device set "${iface}" managed no 2>/dev/null || true

    # Flush any stale host IP assignments
    if ip -4 addr show dev "${iface}" 2>/dev/null | grep -q 'inet '; then
        log_warn "Interface ${iface} has host IPv4 address. Flushing stale address..."
        ip addr flush dev "${iface}" 2>/dev/null || true
    fi
}

exec_in_ns() {
    local ns="$1"
    shift
    if [[ -n "${ns}" ]] && ns_exists "${ns}"; then
        ip netns exec "${ns}" "$@"
    else
        "$@"
    fi
}

is_ip_reachable() {
    local target="$1"
    local timeout="${2:-1}"
    local ns="${3:-}"
    if [[ -n "${ns}" ]] && ns_exists "${ns}"; then
        ip netns exec "${ns}" ping -c 1 -W "${timeout}" "${target}" >/dev/null 2>&1
    else
        ping -c 1 -W "${timeout}" "${target}" >/dev/null 2>&1
    fi
}

wait_for_ping() {
    local target="$1"
    local timeout="${2:-10}"
    local ns="${3:-}"
    local elapsed=0
    while ! is_ip_reachable "${target}" 1 "${ns}"; do
        sleep 1
        elapsed=$((elapsed + 1))
        if (( elapsed >= timeout )); then
            log_warn "Timeout waiting for ping response from ${target} after ${timeout}s"
            return 1
        fi
    done
    return 0
}

bridge_create() {
    local bridge="$1"
    local ip_version="${2:-${IP_VERSION:-4}}"
    if ! bridge_exists "${bridge}"; then
        ip link add name "${bridge}" type bridge
    fi
    ip addr flush dev "${bridge}" 2>/dev/null || true
    # Disable host-level IPv6 stack on test bridge to prevent host SLAAC route pollution (from ipv6_gateway_lab)
    sysctl -q -w "net.ipv6.conf.${bridge}.disable_ipv6=1" 2>/dev/null || true
    ip link set dev "${bridge}" type bridge stp_state 0 mcast_snooping 0 2>/dev/null || true
    ip link set dev "${bridge}" up
}

attach_physical_to_bridge() {
    local iface="$1"
    local bridge="$2"
    local ip_version="${3:-${IP_VERSION:-4}}"

    assert_safe_test_if "${iface}"
    command -v nmcli >/dev/null 2>&1 && nmcli device set "${iface}" managed no 2>/dev/null || true
    ip link set dev "${iface}" down
    ip addr flush dev "${iface}" 2>/dev/null || true
    if [[ "${ip_version}" == "6" || "${ip_version}" == "dual" || "${ip_version}" == "dual-stack" || "${ip_version}" == "ds" ]]; then
        sysctl -q -w "net.ipv6.conf.${iface}.disable_ipv6=0" 2>/dev/null || true
        sysctl -q -w "net.ipv6.conf.${iface}.accept_dad=0" 2>/dev/null || true
    fi
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
# Linux Network Namespace (netns) Helpers
# ------------------------------------------------------------------------------
netns_exists() {
    local ns="$1"
    ns_exists "${ns}"
}

netns_create() {
    local ns="$1"
    if ! ns_exists "${ns}"; then
        ip netns add "${ns}"
    fi
    ip -n "${ns}" link set lo up
}

netns_del() {
    local ns="$1"
    if ns_exists "${ns}"; then
        local pids
        pids="$(ip netns pids "${ns}" 2>/dev/null || true)"
        if [[ -n "${pids}" ]]; then
            # shellcheck disable=SC2086
            kill -TERM ${pids} 2>/dev/null || true
            sleep 0.1
            # shellcheck disable=SC2086
            kill -KILL ${pids} 2>/dev/null || true
        fi
        ip netns del "${ns}" 2>/dev/null || true
    fi
}

attach_netns_to_bridge() {
    local ns="$1"
    local bridge="$2"
    local host_veth="$3"
    local peer_veth="$4"
    local cidrv4=""
    local gatewayv4=""
    local cidrv6=""
    local gatewayv6=""
    local hostname=""
    local mac=""
    local ip_mode="${IP_VERSION:-4}"

    if [[ $# -ge 11 ]]; then
        cidrv4="${5:-}"
        gatewayv4="${6:-}"
        cidrv6="${7:-}"
        gatewayv6="${8:-}"
        hostname="${9:-}"
        mac="${10:-}"
        ip_mode="${11:-${IP_VERSION:-4}}"
    else
        local arg5="${5:-}"
        local arg6="${6:-}"
        hostname="${7:-}"
        mac="${8:-}"
        ip_mode="${9:-${IP_VERSION:-4}}"

        if [[ "${ip_mode}" == "6" || "${arg5}" =~ : ]]; then
            cidrv6="${arg5}"
            gatewayv6="${arg6}"
        else
            cidrv4="${arg5}"
            gatewayv4="${arg6}"
        fi
    fi

    netns_create "${ns}"

    ip link del "${host_veth}" 2>/dev/null || true
    ip link add "${host_veth}" type veth peer name "${peer_veth}"
    ip link set "${host_veth}" master "${bridge}"
    ip link set "${host_veth}" up
    ip link set "${peer_veth}" netns "${ns}"

    ip -n "${ns}" link set lo up
    ip -n "${ns}" link set "${peer_veth}" name eth0
    if [[ -n "${mac}" ]]; then
        ip -n "${ns}" link set eth0 address "${mac}" 2>/dev/null || true
    fi
    ip -n "${ns}" link set eth0 up

    # Flush IPv4 and global IPv6 only - preserve link-local fe80:: (RFC 4861 requirement from ipv6_gateway_lab)
    ip -n "${ns}" -4 addr flush dev eth0 2>/dev/null || true
    ip -n "${ns}" -6 addr flush dev eth0 scope global 2>/dev/null || true

    if [[ "${ip_mode}" == "6" || "${ip_mode}" == "dual" || "${ip_mode}" == "dual-stack" || "${ip_mode}" == "ds" || -n "${cidrv6}" ]]; then
        ip -n "${ns}" sysctl -q -w "net.ipv6.conf.all.disable_ipv6=0" 2>/dev/null || true
        ip -n "${ns}" sysctl -q -w "net.ipv6.conf.default.disable_ipv6=0" 2>/dev/null || true
        ip -n "${ns}" sysctl -q -w "net.ipv6.conf.eth0.disable_ipv6=0" 2>/dev/null || true
        ip -n "${ns}" sysctl -q -w "net.ipv6.conf.eth0.addr_gen_mode=0" 2>/dev/null || true
        ip -n "${ns}" sysctl -q -w "net.ipv6.conf.all.accept_dad=0" 2>/dev/null || true
        ip -n "${ns}" sysctl -q -w "net.ipv6.conf.default.accept_dad=0" 2>/dev/null || true
        ip -n "${ns}" sysctl -q -w "net.ipv6.conf.eth0.accept_dad=0" 2>/dev/null || true
        ip -n "${ns}" sysctl -q -w "net.ipv6.conf.eth0.accept_ra=2" 2>/dev/null || true
        ip -n "${ns}" sysctl -q -w "net.ipv6.conf.eth0.autoconf=1" 2>/dev/null || true

        # Ensure immediate link-local address exists (RFC 4861)
        if ! ip netns exec "${ns}" ip -6 -o addr show dev eth0 scope link 2>/dev/null | grep -q 'inet6 '; then
            local host_id="1"
            if [[ "${ns}" =~ [0-9]+$ ]]; then
                host_id="${BASH_REMATCH[0]}"
            elif [[ "${ns}" == "${SERVER_NAME:-ns-server}" ]]; then
                host_id="2"
            elif [[ "${ns}" == "${WAN_NS:-ns-wan}" ]]; then
                host_id="254"
            fi
            ip -n "${ns}" -6 addr add "fe80::${host_id}/64" dev eth0 nodad 2>/dev/null || true
        fi
    fi

    # IPv4 configuration
    if [[ -n "${cidrv4}" ]]; then
        ip -n "${ns}" addr add "${cidrv4}" dev eth0
        printf '%s\n' "${cidrv4%%/*}" > "${STATE_DIR}/ip-${ns}.txt"
    fi
    if [[ -n "${gatewayv4}" ]]; then
        ip -n "${ns}" route replace default via "${gatewayv4}" dev eth0 2>/dev/null || true
        printf '%s\n' "${gatewayv4}" > "${STATE_DIR}/gw-${ns}.txt"
    fi

    # IPv6 configuration
    if [[ -n "${cidrv6}" ]]; then
        ip -n "${ns}" -6 addr add "${cidrv6}" dev eth0 nodad
        printf '%s\n' "${cidrv6%%/*}" > "${STATE_DIR}/ip6-${ns}.txt"
    fi
    if [[ -n "${gatewayv6}" ]]; then
        ip -n "${ns}" -6 route replace default via "${gatewayv6}" dev eth0 2>/dev/null || true
        printf '%s\n' "${gatewayv6}" > "${STATE_DIR}/gw6-${ns}.txt"
    fi

    ip -n "${ns}" link set eth0 up

    # Multicast routing & group membership tunings
    if [[ "${ip_mode}" == "4" || "${ip_mode}" == "dual" || "${ip_mode}" == "dual-stack" || "${ip_mode}" == "ds" || -n "${cidrv4}" ]]; then
        ip -n "${ns}" route replace 224.0.0.0/4 dev eth0 2>/dev/null || true
        ip -n "${ns}" sysctl -q -w "net.ipv4.conf.all.force_igmp_version=${FORCE_IGMP_VERSION:-2}" 2>/dev/null || true
        ip -n "${ns}" sysctl -q -w "net.ipv4.conf.eth0.force_igmp_version=${FORCE_IGMP_VERSION:-2}" 2>/dev/null || true
        ip -n "${ns}" sysctl -q -w "net.ipv4.igmp_max_memberships=256" 2>/dev/null || true
    fi

    if [[ "${ip_mode}" == "6" || "${ip_mode}" == "dual" || "${ip_mode}" == "dual-stack" || "${ip_mode}" == "ds" || -n "${cidrv6}" ]]; then
        ip -n "${ns}" -6 route replace ff00::/8 dev eth0 2>/dev/null || true
        ip -n "${ns}" sysctl -q -w "net.ipv6.conf.all.force_mld_version=${FORCE_MLD_VERSION:-2}" 2>/dev/null || true
        ip -n "${ns}" sysctl -q -w "net.ipv6.conf.eth0.force_mld_version=${FORCE_MLD_VERSION:-2}" 2>/dev/null || true
        wait_for_ipv6_dad "${ns}" eth0 5
    fi

    if [[ -n "${hostname}" ]]; then
        printf '%s\n' "${hostname}" > "${STATE_DIR}/hostname-${ns}.txt"
    fi
    if [[ -n "${mac}" ]]; then
        printf '%s\n' "${mac}" > "${STATE_DIR}/mac-${ns}.txt"
    fi
}

force_netns_igmp_version() {
    local ns="$1"
    local version="$2"
    if ns_exists "${ns}"; then
        ip -n "${ns}" sysctl -q -w "net.ipv4.conf.all.force_igmp_version=${version}" 2>/dev/null || true
        ip -n "${ns}" sysctl -q -w "net.ipv4.conf.eth0.force_igmp_version=${version}" 2>/dev/null || true
        ip -n "${ns}" sysctl -q -w "net.ipv4.igmp_max_memberships=256" 2>/dev/null || true
    fi
}

force_netns_mld_version() {
    local ns="$1"
    local version="${2:-2}"
    if ns_exists "${ns}"; then
        ip -n "${ns}" sysctl -q -w "net.ipv6.conf.all.disable_ipv6=0" 2>/dev/null || true
        ip -n "${ns}" sysctl -q -w "net.ipv6.conf.eth0.disable_ipv6=0" 2>/dev/null || true
        ip -n "${ns}" sysctl -q -w "net.ipv6.conf.all.force_mld_version=${version}" 2>/dev/null || true
        ip -n "${ns}" sysctl -q -w "net.ipv6.conf.eth0.force_mld_version=${version}" 2>/dev/null || true
    fi
}

wait_for_ipv6_dad() {
    local ns="${1:-}"
    local iface="${2:-eth0}"
    local max_wait="${3:-5}"
    local prefix=()
    if [[ -n "${ns}" ]] && ns_exists "${ns}"; then
        prefix=("ip" "netns" "exec" "${ns}")
    fi

    local i
    for (( i=0; i<max_wait*10; i++ )); do
        if ! "${prefix[@]}" ip -6 addr show dev "${iface}" 2>/dev/null | grep -q "tentative"; then
            return 0
        fi
        sleep 0.1
    done
    return 0
}

run_in_netns_user() {
    local ns="$1"
    shift
    if [[ ${EUID} -eq 0 ]]; then
        local user="${SUDO_USER:-}"
        if [[ -z "${user}" || "${user}" == "root" ]]; then
            user="$(awk -F: '$3 >= 1000 && $3 < 65534 {print $1; exit}' /etc/passwd 2>/dev/null || echo "nobody")"
        fi
        ip netns exec "${ns}" runuser -u "${user}" -- "$@"
    else
        ip netns exec "${ns}" "$@"
    fi
}

# ------------------------------------------------------------------------------
# STB Client Scaling Helpers
# ------------------------------------------------------------------------------
get_client_count() {
    local count="${CLIENT_COUNT:-5}"
    if [[ -f "${STATE_DIR}/topology_state.env" ]]; then
        local saved_count
        saved_count="$(grep '^CLIENT_COUNT=' "${STATE_DIR}/topology_state.env" 2>/dev/null | cut -d= -f2 | tr -d "'\"")"
        if [[ -n "${saved_count}" && "${saved_count}" =~ ^[0-9]+$ ]]; then
            count="${saved_count}"
        fi
    fi
    printf '%s\n' "${count}"
}

get_client_name() {
    local idx="$1"
    if [[ "${idx}" == "1" && -n "${CLIENT1_NAME:-}" ]]; then
        printf '%s\n' "${CLIENT1_NAME}"
    elif [[ "${idx}" == "2" && -n "${CLIENT2_NAME:-}" ]]; then
        printf '%s\n' "${CLIENT2_NAME}"
    else
        printf '%s%d\n' "${CLIENT_PREFIX:-ns-stb}" "${idx}"
    fi
}

get_client_hostname() {
    local idx="$1"
    if [[ "${idx}" == "1" && -n "${CLIENT1_HOSTNAME:-}" ]]; then
        printf '%s\n' "${CLIENT1_HOSTNAME}"
    elif [[ "${idx}" == "2" && -n "${CLIENT2_HOSTNAME:-}" ]]; then
        printf '%s\n' "${CLIENT2_HOSTNAME}"
    else
        printf '%s-%02d\n' "${CLIENT_HOSTNAME_PREFIX:-stb}" "${idx}"
    fi
}

get_client_mac() {
    local idx="$1"
    printf '02:54:00:20:00:%02x\n' "${idx}"
}

get_client_ip() {
    local idx="$1"
    if [[ "${idx}" == "1" && -n "${CLIENT1_IP:-}" ]]; then
        printf '%s\n' "${CLIENT1_IP}"
    elif [[ "${idx}" == "2" && -n "${CLIENT2_IP:-}" ]]; then
        printf '%s\n' "${CLIENT2_IP}"
    else
        printf '10.20.0.%d/24\n' "$(( 10 + idx ))"
    fi
}

get_client_ip6() {
    local idx="$1"
    if [[ "${idx}" == "1" && -n "${CLIENT1_IP6:-}" ]]; then
        printf '%s\n' "${CLIENT1_IP6}"
    elif [[ "${idx}" == "2" && -n "${CLIENT2_IP6:-}" ]]; then
        printf '%s\n' "${CLIENT2_IP6}"
    else
        printf '%s%d/64\n' "${CLIENT_PREFIX_IP6:-fd00:10:20::}" "$(( 10 + idx ))"
    fi
}

get_all_client_names() {
    local count
    count="$(get_client_count)"
    local i
    for (( i=1; i<=count; i++ )); do
        get_client_name "${i}"
    done
}

get_active_client_names() {
    local active_list
    active_list="$(ip netns list 2>/dev/null | awk '{print $1}' | grep -E '^ns-stb[0-9]+$' | sort -V || true)"
    if [[ -n "${active_list}" ]]; then
        printf '%s\n' "${active_list}"
    else
        get_all_client_names
    fi
}

# Compatibility wrappers
container_exists() { netns_exists "$@"; }
attach_container_to_bridge() { attach_netns_to_bridge "$@"; }
force_container_igmp_version() { force_netns_igmp_version "$@"; }


# ------------------------------------------------------------------------------
# Virtual DUT Simulation
# ------------------------------------------------------------------------------
setup_virtual_dut() {
    local ip_version="${1:-${IP_VERSION:-4}}"
    local ns_dut="ns-dut"
    log_info "Creating simulated DUT router ${ns_dut} (IPv${ip_version})..."

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

    if [[ "${ip_version}" == "4" || "${ip_version}" == "dual" || "${ip_version}" == "dual-stack" || "${ip_version}" == "ds" ]]; then
        ip netns exec "${ns_dut}" ip addr add "${DUT_WAN_IP}/24" dev br-dut
        ip netns exec "${ns_dut}" ip addr add "${DUT_LAN_IP}/24" dev br-dut
        ip netns exec "${ns_dut}" sysctl -q -w net.ipv4.ip_forward=1 2>/dev/null || true
        ip netns exec "${ns_dut}" sysctl -q -w net.ipv4.conf.all.mc_forwarding=1 2>/dev/null || true
        ip netns exec "${ns_dut}" sysctl -q -w net.ipv4.conf.br-dut.force_igmp_version=2 2>/dev/null || true
        ip netns exec "${ns_dut}" route replace 224.0.0.0/4 dev br-dut 2>/dev/null || true
    fi

    if [[ "${ip_version}" == "6" || "${ip_version}" == "dual" || "${ip_version}" == "dual-stack" || "${ip_version}" == "ds" ]]; then
        ip netns exec "${ns_dut}" sysctl -q -w net.ipv6.conf.all.disable_ipv6=0 2>/dev/null || true
        ip netns exec "${ns_dut}" sysctl -q -w net.ipv6.conf.default.disable_ipv6=0 2>/dev/null || true
        ip netns exec "${ns_dut}" sysctl -q -w net.ipv6.conf.br-dut.disable_ipv6=0 2>/dev/null || true
        ip netns exec "${ns_dut}" sysctl -q -w net.ipv6.conf.all.accept_dad=0 2>/dev/null || true
        ip netns exec "${ns_dut}" sysctl -q -w net.ipv6.conf.default.accept_dad=0 2>/dev/null || true
        ip netns exec "${ns_dut}" sysctl -q -w net.ipv6.conf.br-dut.accept_dad=0 2>/dev/null || true
        ip netns exec "${ns_dut}" ip -6 addr add "fe80::1/64" dev br-dut nodad 2>/dev/null || true
        ip netns exec "${ns_dut}" ip addr add "${DUT_WAN_IP6:-fd00:10:10::1}/64" dev br-dut nodad
        ip netns exec "${ns_dut}" ip addr add "${DUT_LAN_IP6:-fd00:10:20::1}/64" dev br-dut nodad
        ip netns exec "${ns_dut}" ip -6 route replace ff00::/8 dev br-dut 2>/dev/null || true
        ip netns exec "${ns_dut}" sysctl -q -w net.ipv6.conf.all.forwarding=1 2>/dev/null || true
        ip netns exec "${ns_dut}" sysctl -q -w net.ipv6.conf.all.mc_forwarding=1 2>/dev/null || true
        ip netns exec "${ns_dut}" sysctl -q -w net.ipv6.conf.br-dut.force_mld_version=2 2>/dev/null || true
        wait_for_ipv6_dad "${ns_dut}" br-dut 5
    fi

    ip netns exec "${ns_dut}" ip link set br-dut up
    log_info "Simulated DUT ready (${ip_version}): WAN (${DUT_WAN_IP} / ${DUT_WAN_IP6}) & LAN (${DUT_LAN_IP} / ${DUT_LAN_IP6}) with multicast forwarding"
}

# ------------------------------------------------------------------------------
# Kea & radvd Runtime Preparation and Template Rendering
# ------------------------------------------------------------------------------
prepare_kea_runtime() {
    # 1. Unload AppArmor profiles if active on host (prevents logger_lockfile & pidfile EACCES)
    if command -v apparmor_parser >/dev/null 2>&1; then
        apparmor_parser -R /etc/apparmor.d/usr.sbin.kea-dhcp4 2>/dev/null || true
        apparmor_parser -R /etc/apparmor.d/usr.sbin.kea-dhcp6 2>/dev/null || true
    fi

    # 2. Ensure Kea runtime directories exist with full permissions
    install -d -m 0777 /run/kea /run/lock/kea "${STATE_DIR}/kea"
    chmod 0777 /run/kea /run/lock/kea "${STATE_DIR}/kea" 2>/dev/null || true
    rm -f /run/kea/logger_lockfile /var/run/kea/logger_lockfile /run/lock/kea/logger_lockfile 2>/dev/null || true
    rm -f /run/kea/*.pid /run/lock/kea/*.pid 2>/dev/null || true
    touch /var/log/kea-dhcp6.log 2>/dev/null && chmod 0666 /var/log/kea-dhcp6.log 2>/dev/null || true
}

render_wan_template() {
    local src="$1"
    local dst="$2"
    local iface="${3:-eth0}"

    local v4_dns_list="${WAN_IPV4_DNS:-10.10.0.1}"
    if [[ -n "${WAN_IPV4_DNS2:-}" ]]; then
        v4_dns_list="${WAN_IPV4_DNS}, ${WAN_IPV4_DNS2}"
    fi

    local v6_dns_list="${WAN_IPV6_DNS:-2001:db8:10::1}"
    local v6_radvd_dns="${WAN_IPV6_DNS:-2001:db8:10::1}"
    if [[ -n "${WAN_IPV6_DNS2:-}" ]]; then
        v6_dns_list="${WAN_IPV6_DNS}, ${WAN_IPV6_DNS2}"
        v6_radvd_dns="${WAN_IPV6_DNS} ${WAN_IPV6_DNS2}"
    fi

    sed \
        -e "s|@DUT_IF@|${iface}|g" \
        -e "s|@WAN_IPV4_SUBNET@|${WAN_IPV4_SUBNET:-10.10.0.0/24}|g" \
        -e "s|@WAN_IPV4_POOL_START@|${WAN_IPV4_POOL_START:-10.10.0.100}|g" \
        -e "s|@WAN_IPV4_POOL_END@|${WAN_IPV4_POOL_END:-10.10.0.200}|g" \
        -e "s|@WAN_IPV4_ROUTER@|${WAN_IPV4_ROUTER:-10.10.0.1}|g" \
        -e "s|@WAN_IPV4_DNS@|${v4_dns_list}|g" \
        -e "s|@WAN_IPV4_DNS1@|${WAN_IPV4_DNS:-10.10.0.1}|g" \
        -e "s|@WAN_IPV4_DNS2@|${WAN_IPV4_DNS2:-}|g" \
        -e "s|@WAN_IPV6_PREFIX@|${WAN_IPV6_PREFIX:-2001:db8:10::/64}|g" \
        -e "s|@WAN_IPV6_POOL_START@|${WAN_IPV6_POOL_START:-2001:db8:10::1000}|g" \
        -e "s|@WAN_IPV6_POOL_END@|${WAN_IPV6_POOL_END:-2001:db8:10::1fff}|g" \
        -e "s|@PD_PREFIX@|${PD_PREFIX:-2001:db8:100::}|g" \
        -e "s|@PD_PREFIX_LEN@|${PD_PREFIX_LEN:-56}|g" \
        -e "s|@PD_DELEGATED_LEN@|${PD_DELEGATED_LEN:-60}|g" \
        -e "s|@WAN_IPV6_DNS@|${v6_dns_list}|g" \
        -e "s|@WAN_IPV6_RDNSS@|${v6_radvd_dns}|g" \
        -e "s|@AFTR_NAME@|${AFTR_NAME:-aftr.example.com}|g" \
        -e "s|@DHCP_VALID_LIFETIME_SEC@|${DHCP_VALID_LIFETIME_SEC:-43200}|g" \
        -e "s|@DHCP_RENEW_TIMER_SEC@|${DHCP_RENEW_TIMER_SEC:-21600}|g" \
        -e "s|@DHCP_REBIND_TIMER_SEC@|${DHCP_REBIND_TIMER_SEC:-34560}|g" \
        -e "s|@DHCP6_PREFERRED_LIFETIME_SEC@|${DHCP6_PREFERRED_LIFETIME_SEC:-28800}|g" \
        -e "s|@RA_LIFETIME_SEC@|${RA_LIFETIME_SEC:-1800}|g" \
        -e "s|@RA_MIN_INTERVAL_SEC@|${RA_MIN_INTERVAL_SEC:-3}|g" \
        -e "s|@RA_MAX_INTERVAL_SEC@|${RA_MAX_INTERVAL_SEC:-10}|g" \
        "${src}" > "${dst}"
}

# ------------------------------------------------------------------------------
# WAN DHCP Server Management (inside ns-wan)
# ------------------------------------------------------------------------------
wan_dhcp_server() {
    local action="$1"
    local ip_version="${2:-${IP_VERSION:-4}}"
    local pidfile_dnsmasq="${STATE_DIR}/dnsmasq-wan.pid"
    local pidfile_dnsmasq_v4="${STATE_DIR}/dnsmasq-wan-v4.pid"
    local pidfile_kea4="${STATE_DIR}/kea-dhcp4.pid"
    local pidfile_kea="${STATE_DIR}/kea-dhcp6.pid"
    local pidfile_radvd="${STATE_DIR}/radvd.pid"
    local conffile_dnsmasq="${STATE_DIR}/dnsmasq-wan.conf"
    local leasefile_dnsmasq="${STATE_DIR}/dnsmasq-wan.leases"
    local logfile_dnsmasq="${LOG_DIR}/dnsmasq-wan.log"

    case "${action}" in
        start)
            require_root
            wan_dhcp_server stop >/dev/null 2>&1 || true

            local wan_v4_start="${WAN_IPV4_POOL_START:-${WAN_DHCP_START:-10.10.0.100}}"
            local wan_v4_end="${WAN_IPV4_POOL_END:-${WAN_DHCP_END:-10.10.0.200}}"
            local wan_v4_lease="${DHCP_VALID_LIFETIME_SEC:-${WAN_DHCP_LEASE:-12h}}"
            [[ "${wan_v4_lease}" =~ ^[0-9]+$ ]] && wan_v4_lease="${wan_v4_lease}s"
            local wan_v4_gw="${WAN_IPV4_ROUTER:-${WAN_NS_GW:-${WAN_NS_IP%/*}}}"
            local wan_v4_dns="${WAN_IPV4_DNS:-${wan_v4_gw}}"
            local wan_v4_dns2="${WAN_IPV4_DNS2:-}"

            local wan_v6_prefix="${WAN_IPV6_PREFIX:-${WAN_IPV6_CIDR:-${WAN_NS_IP6:-2001:db8:10::/64}}}"
            local wan_v6_base="${wan_v6_prefix%/*}"
            local wan_v6_start="${WAN_IPV6_POOL_START:-${WAN_DHCP6_START:-${wan_v6_base%::*}::1000}}"
            local wan_v6_end="${WAN_IPV6_POOL_END:-${WAN_DHCP6_END:-${wan_v6_base%::*}::1fff}}"
            local wan_v6_gw="${WAN_IPV6_DNS:-${WAN_NS_GW6:-${WAN_NS_IP6%/*}}}"
            local wan_v6_dns="${WAN_IPV6_DNS:-${wan_v6_gw}}"
            local wan_v6_dns2="${WAN_IPV6_DNS2:-}"

            local is_v6=0
            local is_v4=0
            if [[ "${ip_version}" == "dual" || "${ip_version}" == "dual-stack" || "${ip_version}" == "ds" ]]; then
                is_v6=1
                is_v4=1
            elif [[ "${ip_version}" == "6" ]]; then
                is_v6=1
            else
                is_v4=1
            fi

            local backend="${WAN_DHCP_BACKEND:-auto}"
            local use_kea=0
            if (( is_v6 == 1 )); then
                if [[ "${backend}" == "kea" ]]; then
                    use_kea=1
                elif [[ "${backend}" == "auto" && -n "${PD_PREFIX:-}" ]]; then
                    if command -v kea-dhcp6 >/dev/null 2>&1 && command -v radvd >/dev/null 2>&1; then
                        use_kea=1
                    fi
                fi
            fi

            if (( use_kea == 1 )); then
                prepare_kea_runtime
                local kea_tmpl="${PROJECT_ROOT}/config/kea/kea-dhcp6.conf.in"
                local radvd_tmpl="${PROJECT_ROOT}/config/radvd/radvd.conf.in"
                local kea_conf="${STATE_DIR}/kea-dhcp6.conf"
                local radvd_conf="${STATE_DIR}/radvd.conf"

                # Ensure link-local exists on eth0 for raw socket binding
                if ! ip netns exec "${WAN_NS}" ip -6 -o addr show dev eth0 scope link 2>/dev/null | grep -q 'inet6 '; then
                    ip -n "${WAN_NS}" -6 addr add "fe80::254/64" dev eth0 nodad 2>/dev/null || true
                fi

                # Enable IPv6 forwarding and RA processing in ns-wan
                ip netns exec "${WAN_NS}" sysctl -q -w net.ipv6.conf.all.forwarding=1 2>/dev/null || true
                ip netns exec "${WAN_NS}" sysctl -q -w net.ipv6.conf.default.forwarding=1 2>/dev/null || true
                ip netns exec "${WAN_NS}" sysctl -q -w net.ipv6.conf.eth0.forwarding=1 2>/dev/null || true

                render_wan_template "${kea_tmpl}" "${kea_conf}" "eth0"
                render_wan_template "${radvd_tmpl}" "${radvd_conf}" "eth0"
                chmod 0644 "${radvd_conf}" 2>/dev/null || true

                # Start radvd (M=1, O=1)
                ip netns exec "${WAN_NS}" radvd -C "${radvd_conf}" -p "${pidfile_radvd}" -m logfile -l "${LOG_DIR}/radvd.log"
                log_info "radvd started in ${WAN_NS} (M=1, O=1) [PID $(cat "${pidfile_radvd}" 2>/dev/null || echo '?')]"

                # Start Kea DHCPv6 (IA_NA + IA_PD)
                nohup ip netns exec "${WAN_NS}" \
                    env KEA_PIDFILE_DIR="/run/kea" KEA_LOCKFILE_DIR="/run/lock/kea" \
                    kea-dhcp6 -c "${kea_conf}" > "${LOG_DIR}/kea-dhcp6.log" 2>&1 &
                printf '%s\n' "$!" > "${pidfile_kea}"
                sleep 0.5

                if is_pidfile_running "${pidfile_kea}" && ! grep -q "DHCPSRV_NO_SOCKETS_OPEN" "${LOG_DIR}/kea-dhcp6.log" 2>/dev/null; then
                    log_info "WAN DHCPv6 Server (kea-dhcp6) started in ${WAN_NS} (IA_NA + IA_PD: ${PD_PREFIX}/${PD_PREFIX_LEN} -> /${PD_DELEGATED_LEN}) [PID $(cat "${pidfile_kea}")]"
                else
                    log_warn "kea-dhcp6 failed to start or bind sockets. Falling back to dnsmasq..."
                    stop_pidfile "${pidfile_kea}"
                    stop_pidfile "${pidfile_radvd}"
                    use_kea=0
                fi
            fi

            # Start IPv4 DHCP server
            if (( is_v4 == 1 )); then
                local kea4_started=0
                if (( use_kea == 1 )) && command -v kea-dhcp4 >/dev/null 2>&1; then
                    prepare_kea_runtime
                    local kea4_tmpl="${PROJECT_ROOT}/config/kea/kea-dhcp4.conf.in"
                    local kea4_conf="${STATE_DIR}/kea-dhcp4.conf"
                    render_wan_template "${kea4_tmpl}" "${kea4_conf}" "eth0"

                    nohup ip netns exec "${WAN_NS}" \
                        env KEA_PIDFILE_DIR="/run/kea" KEA_LOCKFILE_DIR="/run/lock/kea" \
                        kea-dhcp4 -c "${kea4_conf}" > "${LOG_DIR}/kea-dhcp4.log" 2>&1 &
                    printf '%s\n' "$!" > "${pidfile_kea4}"
                    sleep 0.5

                    if is_pidfile_running "${pidfile_kea4}"; then
                        log_info "WAN DHCPv4 Server (kea-dhcp4) started in ${WAN_NS} [PID $(cat "${pidfile_kea4}")]"
                        kea4_started=1
                    else
                        log_warn "kea-dhcp4 failed to start. Falling back to dnsmasq for IPv4..."
                        stop_pidfile "${pidfile_kea4}"
                    fi
                fi

                # If Kea4 wasn't used or failed, run dnsmasq for IPv4
                if (( kea4_started == 0 )); then
                    require_cmd dnsmasq
                    touch "${leasefile_dnsmasq}"
                    chmod 0666 "${leasefile_dnsmasq}" 2>/dev/null || true
                    local conf_v4="${STATE_DIR}/dnsmasq-wan-v4.conf"
                    cat >"${conf_v4}" <<EOF
port=0
no-resolv
no-hosts
bind-interfaces
interface=eth0
dhcp-range=${wan_v4_start},${wan_v4_end},255.255.255.0,${wan_v4_lease}
dhcp-option=option:router,${wan_v4_gw}
dhcp-option=option:dns-server,${wan_v4_dns}
dhcp-authoritative
dhcp-leasefile=${leasefile_dnsmasq}
log-facility=${logfile_dnsmasq}
log-dhcp
EOF
                    if [[ -n "${DUT_WAN_MAC:-}" ]]; then
                        printf 'dhcp-host=%s,%s\n' "${DUT_WAN_MAC}" "${DUT_WAN_IP}" >>"${conf_v4}"
                    fi
                    ip netns exec "${WAN_NS}" dnsmasq --conf-file="${conf_v4}" --pid-file="${pidfile_dnsmasq_v4}"
                    log_info "WAN DHCPv4 Server (dnsmasq fallback) started in ${WAN_NS} [PID $(cat "${pidfile_dnsmasq_v4}" 2>/dev/null || echo '?')]"
                fi
            fi

            # Fallback for IPv6 if Kea was not used/failed
            if (( is_v6 == 1 && use_kea == 0 )); then
                require_cmd dnsmasq
                wait_for_ipv6_dad "${WAN_NS}" eth0 5
                touch "${leasefile_dnsmasq}"
                chmod 0666 "${leasefile_dnsmasq}" 2>/dev/null || true
                local conf_v6="${STATE_DIR}/dnsmasq-wan-v6.conf"
                cat >"${conf_v6}" <<EOF
port=0
no-resolv
no-hosts
bind-interfaces
interface=eth0
enable-ra
dhcp-range=${wan_v6_start},${wan_v6_end},slaac,ra-stateless,64,${wan_v4_lease}
dhcp-range=${wan_v6_start},${wan_v6_end},64,${wan_v4_lease}
dhcp-option=option6:dns-server,[${wan_v6_dns}]
dhcp-authoritative
dhcp-leasefile=${leasefile_dnsmasq}
log-facility=${logfile_dnsmasq}
log-dhcp
EOF
                if [[ -n "${AFTR_NAME:-}" ]]; then
                    printf 'dhcp-option=option6:64,%s\n' "${AFTR_NAME}" >>"${conf_v6}"
                fi
                if [[ -n "${DUT_WAN_MAC:-}" ]]; then
                    printf 'dhcp-host=%s,[%s]\n' "${DUT_WAN_MAC}" "${DUT_WAN_IP6:-2001:db8:10::1}" >>"${conf_v6}"
                fi
                ip netns exec "${WAN_NS}" dnsmasq --conf-file="${conf_v6}" --pid-file="${pidfile_dnsmasq}"
                log_info "WAN DHCPv6 Server (dnsmasq fallback) started in ${WAN_NS} [PID $(cat "${pidfile_dnsmasq}" 2>/dev/null || echo '?')]"
            fi
            ;;

        stop)
            stop_pidfile "${pidfile_kea4}"
            stop_pidfile "${pidfile_kea}"
            stop_pidfile "${pidfile_radvd}"
            stop_pidfile "${pidfile_dnsmasq_v4}"
            stop_pidfile "${pidfile_dnsmasq}"
            if ns_exists "${WAN_NS}"; then
                ip netns exec "${WAN_NS}" pkill -TERM kea-dhcp4 2>/dev/null || true
                ip netns exec "${WAN_NS}" pkill -TERM kea-dhcp6 2>/dev/null || true
                ip netns exec "${WAN_NS}" pkill -TERM radvd 2>/dev/null || true
                ip netns exec "${WAN_NS}" pkill -TERM dnsmasq 2>/dev/null || true
            fi
            rm -f "${conffile_dnsmasq}" "${STATE_DIR}"/dnsmasq-wan-*.conf "${STATE_DIR}"/kea-dhcp*.conf "${STATE_DIR}/radvd.conf" 2>/dev/null || true
            log_info "WAN DHCP Server stopped."
            ;;

        status)
            local running=0
            if is_pidfile_running "${pidfile_kea4}"; then
                printf 'WAN DHCPv4 Server (kea-dhcp4): RUNNING (PID %s in %s)\n' "$(cat "${pidfile_kea4}")" "${WAN_NS}"
                running=1
            fi
            if is_pidfile_running "${pidfile_kea}"; then
                printf 'WAN DHCPv6 Server (kea-dhcp6): RUNNING (PID %s in %s, IA_NA + IA_PD)\n' "$(cat "${pidfile_kea}")" "${WAN_NS}"
                running=1
            fi
            if is_pidfile_running "${pidfile_radvd}"; then
                printf 'WAN Router Advertisements (radvd): RUNNING (PID %s in %s)\n' "$(cat "${pidfile_radvd}")" "${WAN_NS}"
                running=1
            fi
            if is_pidfile_running "${pidfile_dnsmasq_v4}"; then
                printf 'WAN DHCPv4 Server (dnsmasq): RUNNING (PID %s in %s)\n' "$(cat "${pidfile_dnsmasq_v4}")" "${WAN_NS}"
                running=1
            fi
            if is_pidfile_running "${pidfile_dnsmasq}"; then
                printf 'WAN DHCP Server (dnsmasq): RUNNING (PID %s in %s)\n' "$(cat "${pidfile_dnsmasq}")" "${WAN_NS}"
                running=1
            fi

            if (( running == 0 )); then
                printf 'WAN DHCP Server: STOPPED\n'
            else
                if [[ -f "${leasefile_dnsmasq}" && -s "${leasefile_dnsmasq}" ]]; then
                    printf '== Active WAN dnsmasq Leases ==\n'
                    cat "${leasefile_dnsmasq}"
                fi
            fi
            ;;
    esac
}

namespace_ip() {
    local ns="${1:-${WAN_NS}}"
    local iface="${2:-eth0}"
    if ns_exists "${ns}"; then
        (ip netns exec "${ns}" ip -4 -o addr show dev "${iface}" 2>/dev/null || true) | awk '{print $4}' | cut -d/ -f1 | head -n1 || echo ""
    else
        (ip -4 -o addr show dev "${iface}" 2>/dev/null || true) | awk '{print $4}' | cut -d/ -f1 | head -n1 || echo ""
    fi
}

namespace_ipv6() {
    local ns="${1:-${WAN_NS}}"
    local iface="${2:-eth0}"
    if ns_exists "${ns}"; then
        (ip netns exec "${ns}" ip -6 -o addr show dev "${iface}" scope global 2>/dev/null || true) | awk '{print $4}' | cut -d/ -f1 | head -n1 || echo ""
    else
        (ip -6 -o addr show dev "${iface}" scope global 2>/dev/null || true) | awk '{print $4}' | cut -d/ -f1 | head -n1 || echo ""
    fi
}

namespace_mac() {
    local ns="${1:-${WAN_NS}}"
    local iface="${2:-eth0}"
    if ns_exists "${ns}"; then
        (ip netns exec "${ns}" cat "/sys/class/net/${iface}/address" 2>/dev/null || true) | head -n1
    else
        (cat "/sys/class/net/${iface}/address" 2>/dev/null || true) | head -n1
    fi
}

is_ip_reachable() {
    local target="$1"
    local timeout="${2:-1}"
    local ns="${3:-}"
    local ping_bin="ping"
    if [[ "${target}" =~ : ]]; then
        ping_bin="ping -6"
    fi

    if [[ -n "${ns}" ]] && ns_exists "${ns}"; then
        ip netns exec "${ns}" ${ping_bin} -c 1 -W "${timeout}" "${target}" >/dev/null 2>&1
    else
        ${ping_bin} -c 1 -W "${timeout}" "${target}" >/dev/null 2>&1
    fi
}

wait_for_ping() {
    local target="$1"
    local timeout="${2:-10}"
    local ns="${3:-}"
    local elapsed=0
    while ! is_ip_reachable "${target}" 1 "${ns}"; do
        sleep 1
        elapsed=$((elapsed + 1))
        if (( elapsed >= timeout )); then
            log_warn "Timeout waiting for ping response from ${target} after ${timeout}s"
            return 1
        fi
    done
    return 0
}

# ------------------------------------------------------------------------------
# Direct Standalone WAN Server & DHCP Helpers (Host-level, no topology bridge)
# ------------------------------------------------------------------------------
configure_direct_wan_interface() {
    local iface="$1"
    local cidrv4="${2:-}"
    local cidrv6="${3:-}"
    local ip_mode="${4:-${IP_VERSION:-4}}"

    # Backward compatibility: if only 2 args passed
    if [[ $# -eq 2 ]]; then
        if [[ "${2}" =~ : ]]; then
            cidrv6="${2}"
            cidrv4=""
            ip_mode="6"
        else
            cidrv4="${2}"
            cidrv6=""
            ip_mode="4"
        fi
    fi

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

    # Flush previous test addresses
    ip -4 addr flush dev "${iface}" 2>/dev/null || true
    ip -6 addr flush dev "${iface}" scope global 2>/dev/null || true

    # Configure IPv4
    if [[ -n "${cidrv4}" ]]; then
        ip addr add "${cidrv4}" dev "${iface}"
        ip route replace 224.0.0.0/4 dev "${iface}" 2>/dev/null || true
        if [[ -w "/proc/sys/net/ipv4/conf/${iface}/force_igmp_version" ]]; then
            printf '2\n' > "/proc/sys/net/ipv4/conf/${iface}/force_igmp_version" 2>/dev/null || true
        fi
    fi

    # Configure IPv6
    if [[ -n "${cidrv6}" ]]; then
        sysctl -q -w "net.ipv6.conf.${iface}.disable_ipv6=0" 2>/dev/null || true
        sysctl -q -w "net.ipv6.conf.${iface}.accept_dad=0" 2>/dev/null || true
        ip -6 addr add "${cidrv6}" dev "${iface}" nodad 2>/dev/null || true
        ip -6 route replace ff00::/8 dev "${iface}" 2>/dev/null || true
        if [[ -w "/proc/sys/net/ipv6/conf/${iface}/force_mld_version" ]]; then
            printf '%s\n' "${FORCE_MLD_VERSION:-2}" > "/proc/sys/net/ipv6/conf/${iface}/force_mld_version" 2>/dev/null || true
        fi
        wait_for_ipv6_dad "" "${iface}" 5
    fi

    log_info "Interface ${iface} configured for direct WAN IPTV streaming (mode: ${ip_mode})."
}

restore_physical_interface() {
    local iface="$1"
    require_root

    [[ -n "${iface}" ]] || return 0
    iface_exists_root "${iface}" || return 0

    log_info "Restoring interface ${iface} to UP state with DHCP..."

    # 1. Detach from bridge master if any
    ip link set dev "${iface}" nomaster 2>/dev/null || true

    # 2. Delete test multicast routes
    if ip route show 224.0.0.0/4 2>/dev/null | grep -Eq "dev[[:space:]]+${iface}([[:space:]]|$)"; then
        ip route del 224.0.0.0/4 dev "${iface}" 2>/dev/null || true
    fi
    if ip -6 route show ff00::/8 2>/dev/null | grep -Eq "dev[[:space:]]+${iface}([[:space:]]|$)"; then
        ip -6 route del ff00::/8 dev "${iface}" 2>/dev/null || true
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
    if ip -6 route show ff00::/8 2>/dev/null | grep -Eq "dev[[:space:]]+${iface}([[:space:]]|$)"; then
        ip -6 route del ff00::/8 dev "${iface}" 2>/dev/null || true
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
    local ip_version="${3:-${IP_VERSION:-4}}"
    local pidfile="${STATE_DIR}/dnsmasq-direct.pid"
    local conffile="${STATE_DIR}/dnsmasq-direct.conf"
    local leasefile="${STATE_DIR}/dnsmasq-direct.leases"
    local logfile="${LOG_DIR}/dnsmasq-direct.log"

    case "${action}" in
        start)
            require_root
            require_cmd dnsmasq
            stop_pidfile "${pidfile}"

            if [[ "${ip_version}" == "6" ]]; then
                wait_for_ipv6_dad "" "${iface}" 5
                cat >"${conffile}" <<EOF
port=0
no-resolv
no-hosts
bind-interfaces
interface=${iface}
enable-ra
dhcp-range=${WAN_IPV6_POOL_START:-2001:db8:10::1000},${WAN_IPV6_POOL_END:-2001:db8:10::1fff},slaac,ra-stateless,64,${WAN_DHCP_LEASE}
dhcp-range=${WAN_IPV6_POOL_START:-2001:db8:10::1000},${WAN_IPV6_POOL_END:-2001:db8:10::1fff},64,${WAN_DHCP_LEASE}
dhcp-option=option6:dns-server,[${WAN_IPV6_DNS:-2001:db8:10::1}]
dhcp-authoritative
dhcp-leasefile=${leasefile}
log-facility=${logfile}
log-dhcp
EOF
                if [[ -n "${DUT_WAN_MAC:-}" ]]; then
                    printf 'dhcp-host=%s,[%s]\n' "${DUT_WAN_MAC}" "${DUT_WAN_IP6:-2001:db8:10::1000}" >>"${conffile}"
                fi
            else
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
            fi

            touch "${leasefile}"
            chmod 0666 "${leasefile}" 2>/dev/null || true

            dnsmasq --conf-file="${conffile}" --pid-file="${pidfile}"
            log_info "Direct WAN DHCP Server (dnsmasq) started on ${iface} (IPv${ip_version}) [PID $(cat "${pidfile}" 2>/dev/null || echo '?')]"
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

# ------------------------------------------------------------------------------
# Socket & Port Synchronization (Eliminates arbitrary sleeps)
# ------------------------------------------------------------------------------
is_port_listening() {
    local port="$1"
    local host="${2:-127.0.0.1}"
    local ns="${3:-}"
    if [[ -n "${ns}" ]] && ns_exists "${ns}"; then
        ip netns exec "${ns}" python3 -c "import socket; s = socket.socket(); s.settimeout(0.5); s.connect(('${host}', int(${port}))); s.close()" >/dev/null 2>&1
    else
        python3 -c "import socket; s = socket.socket(); s.settimeout(0.5); s.connect(('${host}', int(${port}))); s.close()" >/dev/null 2>&1
    fi
}

wait_for_port() {
    local port="$1"
    local host="${2:-127.0.0.1}"
    local timeout="${3:-10}"
    local ns="${4:-}"
    local elapsed=0
    while ! is_port_listening "${port}" "${host}" "${ns}"; do
        sleep 0.5
        elapsed=$((elapsed + 1))
        if (( elapsed >= timeout * 2 )); then
            log_warn "Timeout waiting for port ${port} on ${host} after ${timeout}s"
            return 1
        fi
    done
    return 0
}

wait_for_http() {
    local url="$1"
    local expected_code="${2:-200}"
    local timeout="${3:-10}"
    local ns="${4:-}"
    local elapsed=0
    local curl_cmd=("curl" "-sk" "-o" "/dev/null" "-w" "%{http_code}" "--max-time" "1" "${url}")
    if [[ -n "${ns}" ]] && ns_exists "${ns}"; then
        curl_cmd=("ip" "netns" "exec" "${ns}" "${curl_cmd[@]}")
    fi
    while true; do
        local code
        code="$("${curl_cmd[@]}" 2>/dev/null || echo "000")"
        if [[ "${code}" == "${expected_code}" || ("${expected_code}" == "any" && "${code}" != "000") ]]; then
            return 0
        fi
        sleep 0.5
        elapsed=$((elapsed + 1))
        if (( elapsed >= timeout * 2 )); then
            log_warn "Timeout waiting for HTTP URL ${url} (code: ${code}) after ${timeout}s"
            return 1
        fi
    done
}

# ------------------------------------------------------------------------------
# Remote DUT Management via SSH
# ------------------------------------------------------------------------------
run_dut_cmd() {
    local cmd="$1"
    local timeout="${2:-10}"
    if [[ -z "${DUT_SSH_HOST:-}" || -z "${cmd}" ]]; then
        return 0
    fi
    require_command ssh
    local ssh_opts=(-o ConnectTimeout="${timeout}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o LogLevel=ERROR)
    [[ -n "${DUT_SSH_PORT:-}" ]] && ssh_opts+=(-p "${DUT_SSH_PORT}")
    [[ -n "${DUT_SSH_KEY:-}" && -f "${DUT_SSH_KEY}" ]] && ssh_opts+=(-i "${DUT_SSH_KEY}")
    ssh "${ssh_opts[@]}" "${DUT_SSH_USER:-root}@${DUT_SSH_HOST}" "${cmd}"
}

is_dut_ssh_ready() {
    [[ -z "${DUT_SSH_HOST:-}" ]] && return 1
    run_dut_cmd "echo ok" 3 >/dev/null 2>&1
}

# ------------------------------------------------------------------------------
# PCAP Evidence & Inspection Utilities
# ------------------------------------------------------------------------------
get_latest_pcap() {
    if [[ -f "${STATE_DIR}/last_capture.env" ]]; then
        local pcap_from_env
        pcap_from_env="$(grep '^LAST_PCAP=' "${STATE_DIR}/last_capture.env" 2>/dev/null | cut -d= -f2- | tr -d "'\"" || true)"
        if [[ -n "${pcap_from_env}" && -f "${pcap_from_env}" ]]; then
            printf '%s\n' "${pcap_from_env}"
            return 0
        fi
    fi
    if [[ -f "${STATE_DIR}/latest_capture.txt" ]]; then
        local pcap_from_txt
        pcap_from_txt="$(cat "${STATE_DIR}/latest_capture.txt" 2>/dev/null || true)"
        if [[ -n "${pcap_from_txt}" && -f "${pcap_from_txt}" ]]; then
            printf '%s\n' "${pcap_from_txt}"
            return 0
        fi
    fi
    if [[ -d "${CAPTURE_DIR}" ]]; then
        local newest
        newest="$(find "${CAPTURE_DIR}" -name '*.pcap*' -type f -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n1 | awk '{print $2}' || true)"
        if [[ -n "${newest}" && -f "${newest}" ]]; then
            printf '%s\n' "${newest}"
            return 0
        fi
    fi
    return 1
}

format_bytes() {
    local bytes="${1:-0}"
    if (( bytes < 1024 )); then
        printf '%d B' "${bytes}"
    elif (( bytes < 1048576 )); then
        printf '%.1f KB' "$((bytes * 10 / 1024))e-1"
    elif (( bytes < 1073741824 )); then
        printf '%.1f MB' "$((bytes * 10 / 1048576))e-1"
    else
        printf '%.1f GB' "$((bytes * 10 / 1073741824))e-1"
    fi
}

detect_tshark_field() {
    local fields_cache="$1"
    shift
    local candidate
    for candidate in "$@"; do
        if grep -Fxq "${candidate}" <<< "${fields_cache}"; then
            printf '%s\n' "${candidate}"
            return 0
        fi
    done
    return 1
}

validate_cert_expiry() {
    local cert_file="$1"
    local days_check="${2:-7}"
    [[ -f "${cert_file}" ]] || return 1
    require_command openssl
    local seconds=$(( days_check * 86400 ))
    openssl x509 -checkend "${seconds}" -noout -in "${cert_file}" >/dev/null 2>&1
}

