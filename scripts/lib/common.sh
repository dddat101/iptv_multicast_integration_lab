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
    if ! bridge_exists "${bridge}"; then
        ip link add name "${bridge}" type bridge
    fi
    ip addr flush dev "${bridge}" 2>/dev/null || true
    sysctl -q -w "net.ipv6.conf.${bridge}.disable_ipv6=1" 2>/dev/null || true
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
    local cidr="${5:-}"
    local gateway="${6:-}"
    local hostname="${7:-}"
    local mac="${8:-}"

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
    ip -n "${ns}" addr flush dev eth0 2>/dev/null || true
    if [[ -n "${cidr}" ]]; then
        ip -n "${ns}" addr add "${cidr}" dev eth0
        printf '%s\n' "${cidr%%/*}" > "${STATE_DIR}/ip-${ns}.txt"
    fi
    ip -n "${ns}" link set eth0 up
    if [[ -n "${gateway}" ]]; then
        ip -n "${ns}" route replace default via "${gateway}" dev eth0 2>/dev/null || true
        printf '%s\n' "${gateway}" > "${STATE_DIR}/gw-${ns}.txt"
    fi

    ip -n "${ns}" sysctl -q -w "net.ipv4.igmp_max_memberships=256" 2>/dev/null || true

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
    if ns_exists "${ns}"; then
        (ip netns exec "${ns}" ip -4 -o addr show dev "${iface}" 2>/dev/null || true) | awk '{print $4}' | cut -d/ -f1 | head -n1 || echo ""
    else
        (ip -4 -o addr show dev "${iface}" 2>/dev/null || true) | awk '{print $4}' | cut -d/ -f1 | head -n1 || echo ""
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

# ------------------------------------------------------------------------------
# Direct Standalone WAN Server & DHCP Helpers (Host-level, no topology bridge)
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

