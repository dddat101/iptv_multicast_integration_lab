#!/usr/bin/env bash
# ==============================================================================
# REAL IPTV MULTICAST TEST LAB - MEDIA SERVER (FFmpeg Streamer)
# Streams MPEG-TS video over UDP Multicast.
# Supports two operating modes:
#   1. Direct Host Mode (--direct): Streams directly out physical WAN_IF with
#      optional direct WAN DHCP server (no topology needed).
#   2. Namespace Mode (--netns): Streams from inside SERVER_NAME network namespace
#      attached to WAN test bridge.
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
PID_FILE=""
LOG_FILE=""
PID_FILE6=""
LOG_FILE6=""
DIRECT_PID_FILE=""
DIRECT_LOG_FILE=""
DIRECT_PID_FILE6=""
DIRECT_LOG_FILE6=""
STATE_MODE_FILE=""
STATE_IFACE_FILE=""
STATE_IFACE_TYPE_FILE=""

init_server_paths() {
    PID_FILE="${STATE_DIR}/server.pid"
    LOG_FILE="${LOG_DIR}/server.log"
    PID_FILE6="${STATE_DIR}/server_v6.pid"
    LOG_FILE6="${LOG_DIR}/server_v6.log"
    DIRECT_PID_FILE="${STATE_DIR}/server_direct.pid"
    DIRECT_LOG_FILE="${LOG_DIR}/server_direct.log"
    DIRECT_PID_FILE6="${STATE_DIR}/server_direct_v6.pid"
    DIRECT_LOG_FILE6="${LOG_DIR}/server_direct_v6.log"
    STATE_MODE_FILE="${STATE_DIR}/server_mode.txt"
    STATE_IFACE_FILE="${STATE_DIR}/server_iface.txt"
    STATE_IFACE_TYPE_FILE="${STATE_DIR}/server_iface_type.txt"
}

TARGET_IFACE=""
STREAM_LOCAL_IP=""

usage() {
    cat <<'USAGE'
Description:
  FFmpeg MPEG-TS UDP multicast streamer manager. Streams 1080p video over UDP
  multicast either directly on host physical Ethernet adapters (--direct) or inside
  isolated network namespaces (--netns) attached to L2 test bridges.

Usage:
  ./scripts/start_server.sh [options] [command]
  ./scripts/start_server.sh -h | --help

Commands:
  run             Run streaming interactively in the foreground [Default if TTY]
  start           Run streaming in background daemon mode
  stop            Stop streaming daemon (direct or namespace)
  status          Show status of media streaming daemon

Options:
  -i, --interface, --iface <iface>
                  Specify physical interface for streaming (e.g. eno1, enxd46e0e0c65e1).
                  Auto-detects IP and avoids flushing shared host interfaces.
  -d, --direct, --standalone
                  Run directly on host WAN_IF (no topology needed)
  -n, --netns, -c, --container
                  Run inside network namespace topology
  -g, --group <ip>
                  Override multicast destination IP (default: from config, e.g. 239.10.10.10)
  -p, --port <port>
                  Override UDP destination port (default: from config, e.g. 5000)
  -4, --ipv4      Stream over IPv4 multicast (default: 239.10.10.10)
  -6, --ipv6      Stream over IPv6 multicast (default: ff0e::10:10:10)
  --dual, --dual-stack, -ds
                  Stream over both IPv4 and IPv6 multicast concurrently
  -h, --help      Show this help message and exit

Examples:
  sudo ./scripts/start_server.sh -i eno1 start
  sudo ./scripts/start_server.sh -i eno1 run
  sudo ./scripts/start_server.sh -4 start
  sudo ./scripts/start_server.sh -6 start
  sudo ./scripts/start_server.sh --dual start
  sudo ./scripts/start_server.sh --direct start
  sudo ./scripts/start_server.sh start
  ./scripts/start_server.sh status
  sudo ./scripts/start_server.sh stop

Suggested Next Steps:
  - Inspect stream status: ./scripts/start_server.sh status
  - Start STB client:      sudo ./scripts/start_client.sh 1 start
  - Run scenario:          sudo ./scripts/scenario.sh
USAGE
}

get_udp_target_url() {
    local group="$1"
    local port="$2"
    if [[ "${group}" =~ : ]]; then
        printf '[%s]:%s' "${group}" "${port}"
    else
        printf '%s:%s' "${group}" "${port}"
    fi
}

check_media_asset() {
    if [[ ! -f "${MEDIA_DIR}/${MEDIA_FILE}" ]]; then
        log_warn "Missing media asset ${MEDIA_DIR}/${MEDIA_FILE}."
        log_info "Auto-generating sample 1080p stream with scripts/generate_media.sh..."
        "${SCRIPT_DIR}/generate_media.sh"
    fi
}

# ------------------------------------------------------------------------------
# Network Namespace Topology Mode Functions
# ------------------------------------------------------------------------------
run_foreground() {
    require_cmd ffmpeg
    check_media_asset
    netns_exists "${SERVER_NAME}" || die "Namespace '${SERVER_NAME}' is not running. Run sudo ./scripts/setup.sh first, or use --direct to stream on host."

    if [[ "${IP_VERSION:-4}" == "dual" || "${IP_VERSION:-4}" == "dual-stack" || "${IP_VERSION:-4}" == "ds" ]]; then
        log_info "Dual-stack foreground: launching IPv6 background stream, running IPv4 in foreground..."
        wait_for_ipv6_dad "${SERVER_NAME}" eth0 5
        ip -n "${SERVER_NAME}" -6 route replace ff00::/8 dev eth0 2>/dev/null || true
        ip -n "${SERVER_NAME}" route replace 224.0.0.0/4 dev eth0 2>/dev/null || true
        local grp6="${MCAST_GROUP6:-ff0e::10:10:10}"
        local url_v6="[${grp6}]:${MCAST_PORT:-5000}"
        nohup ip netns exec "${SERVER_NAME}" ffmpeg -hide_banner -re -stream_loop -1 \
            -i "${MEDIA_DIR}/${MEDIA_FILE}" -c copy -f mpegts \
            "udp://${url_v6}?pkt_size=${MPEGTS_PKT_SIZE}&ttl=${MCAST_TTL}" \
            >"${LOG_FILE6}" 2>&1 &
        local pid6=$!
        printf '%s\n' "${pid6}" > "${PID_FILE6}"
        log_info "IPv6 background stream active [PID ${pid6}]. Now running IPv4 foreground stream..."
        local url_v4="${MCAST_GROUP:-239.10.10.10}:${MCAST_PORT:-5000}"
        ip netns exec "${SERVER_NAME}" ffmpeg -hide_banner -re -stream_loop -1 \
            -i "${MEDIA_DIR}/${MEDIA_FILE}" -c copy -f mpegts \
            "udp://${url_v4}?pkt_size=${MPEGTS_PKT_SIZE}&ttl=${MCAST_TTL}"
        return 0
    fi

    if [[ "${MCAST_GROUP}" =~ : || "${IP_VERSION:-4}" == "6" ]]; then
        wait_for_ipv6_dad "${SERVER_NAME}" eth0 5
        ip -n "${SERVER_NAME}" -6 route replace ff00::/8 dev eth0 2>/dev/null || true
    else
        ip -n "${SERVER_NAME}" route replace 224.0.0.0/4 dev eth0 2>/dev/null || true
    fi

    local url_target
    url_target="$(get_udp_target_url "${MCAST_GROUP}" "${MCAST_PORT}")"
    log_info "Streaming ${url_target} from namespace ${SERVER_NAME} (Foreground)..."
    ip netns exec "${SERVER_NAME}" ffmpeg -hide_banner -re -stream_loop -1 \
        -i "${MEDIA_DIR}/${MEDIA_FILE}" -c copy -f mpegts \
        "udp://${url_target}?pkt_size=${MPEGTS_PKT_SIZE}&ttl=${MCAST_TTL}"
}

start_background() {
    require_cmd ffmpeg
    check_media_asset
    netns_exists "${SERVER_NAME}" || die "Namespace '${SERVER_NAME}' is not running. Run sudo ./scripts/setup.sh first, or use --direct to stream on host."

    if [[ "${IP_VERSION:-4}" == "dual" || "${IP_VERSION:-4}" == "dual-stack" || "${IP_VERSION:-4}" == "ds" ]]; then
        local start_v4=1
        local start_v6=1

        if is_pidfile_running "${PID_FILE}"; then
            log_warn "Namespace IPv4 media server already streaming (PID $(cat "${PID_FILE}"))."
            start_v4=0
        fi
        if is_pidfile_running "${PID_FILE6}"; then
            log_warn "Namespace IPv6 media server already streaming (PID $(cat "${PID_FILE6}"))."
            start_v6=0
        fi

        if (( start_v4 == 1 )); then
            ip -n "${SERVER_NAME}" route replace 224.0.0.0/4 dev eth0 2>/dev/null || true
            local grp4="${MCAST_GROUP:-239.10.10.10}"
            local url_v4="${grp4}:${MCAST_PORT:-5000}"
            log_info "Starting background IPv4 media stream ${url_v4} from ${SERVER_NAME}..."
            nohup ip netns exec "${SERVER_NAME}" ffmpeg -hide_banner -re -stream_loop -1 \
                -i "${MEDIA_DIR}/${MEDIA_FILE}" -c copy -f mpegts \
                "udp://${url_v4}?pkt_size=${MPEGTS_PKT_SIZE}&ttl=${MCAST_TTL}" \
                >"${LOG_FILE}" 2>&1 &
            local pid4=$!
            printf '%s\n' "${pid4}" > "${PID_FILE}"
        fi

        if (( start_v6 == 1 )); then
            wait_for_ipv6_dad "${SERVER_NAME}" eth0 5
            ip -n "${SERVER_NAME}" -6 route replace ff00::/8 dev eth0 2>/dev/null || true
            local grp6="${MCAST_GROUP6:-ff0e::10:10:10}"
            local url_v6="[${grp6}]:${MCAST_PORT:-5000}"
            log_info "Starting background IPv6 media stream ${url_v6} from ${SERVER_NAME}..."
            nohup ip netns exec "${SERVER_NAME}" ffmpeg -hide_banner -re -stream_loop -1 \
                -i "${MEDIA_DIR}/${MEDIA_FILE}" -c copy -f mpegts \
                "udp://${url_v6}?pkt_size=${MPEGTS_PKT_SIZE}&ttl=${MCAST_TTL}" \
                >"${LOG_FILE6}" 2>&1 &
            local pid6=$!
            printf '%s\n' "${pid6}" > "${PID_FILE6}"
        fi

        printf 'netns\n' > "${STATE_MODE_FILE}"
        sleep 0.5

        if (( start_v4 == 1 )) && ! kill -0 "$(cat "${PID_FILE}" 2>/dev/null || echo 0)" 2>/dev/null; then
            log_error "Failed to start IPv4 media server streaming in namespace."
            cat "${LOG_FILE}" >&2 || true
            rm -f "${PID_FILE}"
            return 1
        fi
        if (( start_v6 == 1 )) && ! kill -0 "$(cat "${PID_FILE6}" 2>/dev/null || echo 0)" 2>/dev/null; then
            log_error "Failed to start IPv6 media server streaming in namespace."
            cat "${LOG_FILE6}" >&2 || true
            rm -f "${PID_FILE6}"
            return 1
        fi

        local v4_pid v6_pid
        v4_pid="$(cat "${PID_FILE}" 2>/dev/null || echo '<none>')"
        v6_pid="$(cat "${PID_FILE6}" 2>/dev/null || echo '<none>')"
        log_info "Dual-Stack media streaming running in ${SERVER_NAME} (IPv4 PID ${v4_pid}, IPv6 PID ${v6_pid})."
        return 0
    fi

    if is_pidfile_running "${PID_FILE}"; then
        log_warn "Namespace media server already streaming (PID $(cat "${PID_FILE}"))."
        return 0
    fi

    if [[ "${MCAST_GROUP}" =~ : || "${IP_VERSION:-4}" == "6" ]]; then
        wait_for_ipv6_dad "${SERVER_NAME}" eth0 5
        ip -n "${SERVER_NAME}" -6 route replace ff00::/8 dev eth0 2>/dev/null || true
    else
        ip -n "${SERVER_NAME}" route replace 224.0.0.0/4 dev eth0 2>/dev/null || true
    fi

    local url_target
    url_target="$(get_udp_target_url "${MCAST_GROUP}" "${MCAST_PORT}")"
    log_info "Starting background media stream ${url_target} from ${SERVER_NAME}..."
    nohup ip netns exec "${SERVER_NAME}" ffmpeg -hide_banner -re -stream_loop -1 \
        -i "${MEDIA_DIR}/${MEDIA_FILE}" -c copy -f mpegts \
        "udp://${url_target}?pkt_size=${MPEGTS_PKT_SIZE}&ttl=${MCAST_TTL}" \
        >"${LOG_FILE}" 2>&1 &

    local pid=$!
    printf '%s\n' "${pid}" > "${PID_FILE}"
    printf 'netns\n' > "${STATE_MODE_FILE}"
    sleep 0.5

    if ! kill -0 "${pid}" 2>/dev/null; then
        log_error "Failed to start media server streaming in namespace."
        cat "${LOG_FILE}" >&2 || true
        rm -f "${PID_FILE}"
        return 1
    fi

    log_info "Media server streaming started in ${SERVER_NAME} [PID ${pid}]. Logs: ${LOG_FILE}"
}

stop_background() {
    if is_pidfile_running "${PID_FILE}"; then
        local pid
        pid="$(cat "${PID_FILE}")"
        log_info "Stopping IPv4 media server streaming [PID ${pid}]..."
        stop_pidfile "${PID_FILE}"
    else
        rm -f "${PID_FILE}" 2>/dev/null || true
    fi

    if is_pidfile_running "${PID_FILE6}"; then
        local pid6
        pid6="$(cat "${PID_FILE6}")"
        log_info "Stopping IPv6 media server streaming [PID ${pid6}]..."
        stop_pidfile "${PID_FILE6}"
    else
        rm -f "${PID_FILE6}" 2>/dev/null || true
    fi

    if netns_exists "${SERVER_NAME}"; then
        ip netns exec "${SERVER_NAME}" pkill -TERM -f ffmpeg 2>/dev/null || true
        sleep 0.2
        ip netns exec "${SERVER_NAME}" pkill -KILL -f ffmpeg 2>/dev/null || true
    fi
    log_info "Media server streaming stopped."
}

# ------------------------------------------------------------------------------
# Direct Standalone WAN Mode Functions
# ------------------------------------------------------------------------------
setup_direct_streaming_iface() {
    local iface="$1"
    require_root

    [[ -n "${iface}" ]] || die "Interface name cannot be empty."
    iface_exists_root "${iface}" || die "Interface not found on host: ${iface}"

    # Ensure interface is UP
    ip link set dev "${iface}" up

    # Determine if interface has an existing IPv4 address
    local current_ip
    current_ip="$(ip -4 -o addr show dev "${iface}" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)"

    local is_shared=0
    if ip route show default 2>/dev/null | grep -Eq "dev[[:space:]]+${iface}([[:space:]]|$)"; then
        is_shared=1
    elif [[ -n "${current_ip}" && "${iface}" != "${WAN_IF}" ]]; then
        is_shared=1
    fi

    local stream_local_ip=""

    mkdir -p "${STATE_DIR}" "${LOG_DIR}"

    if (( is_shared == 1 )); then
        # Shared active host interface (e.g. eno1 on corporate/lab network)
        [[ -n "${current_ip}" ]] || die "Shared interface ${iface} does not have an active IPv4 address."
        stream_local_ip="${current_ip}"

        log_info "Using active host interface '${iface}' (IP: ${stream_local_ip}) - preserving existing configuration."
        printf 'shared\n' > "${STATE_IFACE_TYPE_FILE}"
        printf '%s\n' "${iface}" > "${STATE_IFACE_FILE}"

        # Ensure multicast route points out this interface
        if [[ "${MCAST_GROUP}" =~ : || "${IP_VERSION:-4}" == "6" ]]; then
            ip -6 route replace ff00::/8 dev "${iface}" 2>/dev/null || true
        else
            ip route replace 224.0.0.0/4 dev "${iface}"
        fi
    else
        # Dedicated test interface (e.g. enxd46e0e0c65e1)
        if [[ "${IP_VERSION:-4}" == "6" || "${MCAST_GROUP}" =~ : ]]; then
            log_info "Configuring dedicated test interface '${iface}' with IPv6 ${SERVER_IP6}..."
            printf 'dedicated\n' > "${STATE_IFACE_TYPE_FILE}"
            printf '%s\n' "${iface}" > "${STATE_IFACE_FILE}"

            configure_direct_wan_interface "${iface}" "${SERVER_IP6}"

            if [[ "${ENABLE_WAN_DHCP:-0}" == "1" ]]; then
                direct_wan_dhcp_server start "${iface}" "6"
            fi
            stream_local_ip="${SERVER_IP6%/*}"
        else
            log_info "Configuring dedicated test interface '${iface}' with IP ${SERVER_IP}..."
            printf 'dedicated\n' > "${STATE_IFACE_TYPE_FILE}"
            printf '%s\n' "${iface}" > "${STATE_IFACE_FILE}"

            configure_direct_wan_interface "${iface}" "${SERVER_IP}"

            if [[ "${ENABLE_WAN_DHCP:-0}" == "1" ]]; then
                direct_wan_dhcp_server start "${iface}" "4"
            fi
            stream_local_ip="${SERVER_IP%/*}"
        fi
    fi

    # Set IGMPv2/MLDv2 on the interface if writable
    if [[ "${IP_VERSION:-4}" == "6" || "${MCAST_GROUP}" =~ : ]]; then
        if [[ -w "/proc/sys/net/ipv6/conf/${iface}/force_mld_version" ]]; then
            printf '%s\n' "${FORCE_MLD_VERSION:-2}" > "/proc/sys/net/ipv6/conf/${iface}/force_mld_version" 2>/dev/null || true
        fi
    else
        if [[ -w "/proc/sys/net/ipv4/conf/${iface}/force_igmp_version" ]]; then
            printf '2\n' > "/proc/sys/net/ipv4/conf/${iface}/force_igmp_version" 2>/dev/null || true
        fi
    fi

    # MTU detection and packet size adaptation to eliminate fragmentation drops
    local iface_mtu
    iface_mtu="$(cat "/sys/class/net/${iface}/mtu" 2>/dev/null || echo 1500)"
    if (( iface_mtu < 1344 )); then
        log_warn "Interface '${iface}' MTU is ${iface_mtu} (< 1344)."
        log_warn "Auto-adjusting MPEG-TS packet size to 1128B (6 TS packets) to prevent IP fragmentation packet loss."
        MPEGTS_PKT_SIZE=1128
        log_info "Tip: For standard 1316B IPTV packets, run 'sudo ip link set dev ${iface} mtu 1500'."
    fi

    STREAM_LOCAL_IP="${stream_local_ip}"
}

cleanup_direct_streaming_iface() {
    local iface=""
    local iface_type="dedicated"

    if [[ -f "${STATE_IFACE_FILE}" ]]; then
        iface="$(cat "${STATE_IFACE_FILE}" 2>/dev/null || true)"
    fi
    if [[ -f "${STATE_IFACE_TYPE_FILE}" ]]; then
        iface_type="$(cat "${STATE_IFACE_TYPE_FILE}" 2>/dev/null || true)"
    fi
    iface="${iface:-${TARGET_IFACE:-${WAN_IF}}}"

    if [[ "${iface_type}" == "dedicated" ]]; then
        if [[ "${ENABLE_WAN_DHCP:-0}" == "1" ]]; then
            direct_wan_dhcp_server stop 2>/dev/null || true
        fi
        cleanup_direct_wan_interface "${iface}"
    else
        log_info "Preserved configuration on shared host interface ${iface}."
    fi

    rm -f "${STATE_IFACE_FILE}" "${STATE_IFACE_TYPE_FILE}" "${STATE_MODE_FILE}" 2>/dev/null || true
}

run_direct_foreground() {
    local target_iface="${TARGET_IFACE:-${WAN_IF}}"
    require_root
    check_media_asset

    setup_direct_streaming_iface "${target_iface}"
    local local_ip="${STREAM_LOCAL_IP}"
    local url_target
    url_target="$(get_udp_target_url "${MCAST_GROUP}" "${MCAST_PORT}")"

    log_info "Streaming ${url_target} directly on ${target_iface} (localaddr=${local_ip}) [Foreground]..."
    log_info "Press Ctrl+C to terminate streaming."

    if command -v ffmpeg >/dev/null 2>&1; then
        ffmpeg -hide_banner -re -stream_loop -1 \
            -i "${MEDIA_DIR}/${MEDIA_FILE}" -c copy -f mpegts \
            "udp://${url_target}?pkt_size=${MPEGTS_PKT_SIZE}&ttl=${MCAST_TTL}&localaddr=${local_ip}"
    else
        die "ffmpeg is required. Please run: sudo ./scripts/install_deps.sh"
    fi
}

start_direct_background() {
    local target_iface="${TARGET_IFACE:-${WAN_IF}}"
    require_root
    check_media_asset

    if is_pidfile_running "${DIRECT_PID_FILE}"; then
        log_warn "Direct media server already streaming (PID $(cat "${DIRECT_PID_FILE}"))."
        return 0
    fi

    setup_direct_streaming_iface "${target_iface}"
    local local_ip="${STREAM_LOCAL_IP}"
    local url_target
    url_target="$(get_udp_target_url "${MCAST_GROUP}" "${MCAST_PORT}")"

    log_info "Starting direct background media stream ${url_target} on ${target_iface} (localaddr=${local_ip})..."
    local pid

    if command -v ffmpeg >/dev/null 2>&1; then
        nohup ffmpeg -hide_banner -re -stream_loop -1 \
            -i "${MEDIA_DIR}/${MEDIA_FILE}" -c copy -f mpegts \
            "udp://${url_target}?pkt_size=${MPEGTS_PKT_SIZE}&ttl=${MCAST_TTL}&localaddr=${local_ip}" \
            >"${DIRECT_LOG_FILE}" 2>&1 &
        pid=$!
    else
        die "ffmpeg is required. Please run: sudo ./scripts/install_deps.sh"
    fi

    printf '%s\n' "${pid}" > "${DIRECT_PID_FILE}"
    printf 'direct\n' > "${STATE_MODE_FILE}"
    sleep 0.5

    if ! kill -0 "${pid}" 2>/dev/null; then
        log_error "Failed to start direct media server streaming."
        cat "${DIRECT_LOG_FILE}" >&2 || true
        rm -f "${DIRECT_PID_FILE}"
        return 1
    fi

    log_info "Direct media server streaming started on ${target_iface} [PID ${pid}]. Logs: ${DIRECT_LOG_FILE}"
}

stop_direct_background() {
    require_root
    if is_pidfile_running "${DIRECT_PID_FILE}"; then
        local pid
        pid="$(cat "${DIRECT_PID_FILE}")"
        log_info "Stopping direct IPv4 media server streaming [PID ${pid}]..."
        stop_pidfile "${DIRECT_PID_FILE}"
    else
        rm -f "${DIRECT_PID_FILE}" 2>/dev/null || true
    fi

    if is_pidfile_running "${DIRECT_PID_FILE6}"; then
        local pid6
        pid6="$(cat "${DIRECT_PID_FILE6}")"
        log_info "Stopping direct IPv6 media server streaming [PID ${pid6}]..."
        stop_pidfile "${DIRECT_PID_FILE6}"
    else
        rm -f "${DIRECT_PID_FILE6}" 2>/dev/null || true
    fi

    # Terminate any stray host ffmpeg streaming to multicast ports
    pkill -f "udp://.*:${MCAST_PORT}" 2>/dev/null || true

    cleanup_direct_streaming_iface
    log_info "Direct media server streaming stopped."
}

stop_any() {
    local stopped=0
    if is_pidfile_running "${DIRECT_PID_FILE}" || is_pidfile_running "${DIRECT_PID_FILE6}" || [[ -f "${STATE_MODE_FILE}" && "$(cat "${STATE_MODE_FILE}" 2>/dev/null)" == "direct" ]]; then
        stop_direct_background
        stopped=1
    fi
    if is_pidfile_running "${PID_FILE}" || is_pidfile_running "${PID_FILE6}" || netns_exists "${SERVER_NAME}"; then
        stop_background
        stopped=1
    fi
    if (( stopped == 0 )); then
        rm -f "${DIRECT_PID_FILE}" "${DIRECT_PID_FILE6}" "${PID_FILE}" "${PID_FILE6}" "${STATE_MODE_FILE}" "${STATE_IFACE_FILE}" "${STATE_IFACE_TYPE_FILE}" 2>/dev/null || true
        log_info "Media server streaming is already stopped."
    fi
}

show_status() {
    printf '== Media Server Status ==\n'
    local running=0

    if is_pidfile_running "${DIRECT_PID_FILE}"; then
        running=1
        local active_iface="${WAN_IF}"
        local active_type="dedicated"
        if [[ -f "${STATE_IFACE_FILE}" ]]; then
            active_iface="$(cat "${STATE_IFACE_FILE}" 2>/dev/null || echo "${WAN_IF}")"
        fi
        if [[ -f "${STATE_IFACE_TYPE_FILE}" ]]; then
            active_type="$(cat "${STATE_IFACE_TYPE_FILE}" 2>/dev/null || echo "dedicated")"
        fi
        local ip_now
        ip_now="$(ip -4 -o addr show dev "${active_iface}" scope global 2>/dev/null | awk '{print $4}' | head -n1 || echo '<none>')"

        local dir_v_label="IPv4"
        if [[ "${IP_VERSION:-4}" == "6" || "${MCAST_GROUP}" =~ : ]]; then
            dir_v_label="IPv6"
        fi
        local url_dir_target
        url_dir_target="$(get_udp_target_url "${MCAST_GROUP}" "${MCAST_PORT}")"

        printf 'Mode:      DIRECT HOST (%s on %s) [%s]\n' "${active_type}" "${active_iface}" "${dir_v_label}"
        printf 'Status:    STREAMING (PID %s)\n' "$(cat "${DIRECT_PID_FILE}")"
        printf 'Stream:    udp://%s (pkt_size=%s, ttl=%s, localaddr=%s)\n' \
            "${url_dir_target}" "${MPEGTS_PKT_SIZE}" "${MCAST_TTL}" "${ip_now%/*}"
        printf 'Asset:     %s\n' "${MEDIA_FILE}"
        printf 'Iface IP:  %s\n' "${ip_now}"
        if [[ "${active_type}" == "dedicated" ]]; then
            direct_wan_dhcp_server status || true
        fi
    fi

    if is_pidfile_running "${DIRECT_PID_FILE6}"; then
        running=1
        local active_iface="${WAN_IF}"
        local active_type="dedicated"
        if [[ -f "${STATE_IFACE_FILE}" ]]; then
            active_iface="$(cat "${STATE_IFACE_FILE}" 2>/dev/null || echo "${WAN_IF}")"
        fi
        if [[ -f "${STATE_IFACE_TYPE_FILE}" ]]; then
            active_type="$(cat "${STATE_IFACE_TYPE_FILE}" 2>/dev/null || echo "dedicated")"
        fi
        local ip6_now
        ip6_now="$(ip -6 -o addr show dev "${active_iface}" scope global 2>/dev/null | awk '{print $4}' | head -n1 || echo '<none>')"

        printf 'Mode:      DIRECT HOST (%s on %s) [IPv6]\n' "${active_type}" "${active_iface}"
        printf 'Status:    STREAMING (PID %s)\n' "$(cat "${DIRECT_PID_FILE6}")"
        printf 'Stream:    udp://[%s]:%s (pkt_size=%s, ttl=%s, localaddr=%s)\n' \
            "${MCAST_GROUP6:-ff0e::10:10:10}" "${MCAST_PORT}" "${MPEGTS_PKT_SIZE}" "${MCAST_TTL}" "${ip6_now%/*}"
        printf 'Asset:     %s\n' "${MEDIA_FILE}"
        printf 'Iface IP6: %s\n' "${ip6_now}"
    fi

    if is_pidfile_running "${PID_FILE}"; then
        running=1
        local ns_v_label="IPv4"
        if [[ "${IP_VERSION:-4}" == "6" || "${MCAST_GROUP}" =~ : ]]; then
            ns_v_label="IPv6"
        fi
        local url_ns_target
        url_ns_target="$(get_udp_target_url "${MCAST_GROUP}" "${MCAST_PORT}")"
        printf 'Mode:      NAMESPACE (%s) [%s]\n' "${SERVER_NAME}" "${ns_v_label}"
        printf 'Status:    STREAMING (PID %s)\n' "$(cat "${PID_FILE}")"
        printf 'Stream:    udp://%s (pkt_size=%s, ttl=%s)\n' \
            "${url_ns_target}" "${MPEGTS_PKT_SIZE}" "${MCAST_TTL}"
        printf 'Asset:     %s\n' "${MEDIA_FILE}"
    fi

    if is_pidfile_running "${PID_FILE6}"; then
        running=1
        local grp6="${MCAST_GROUP6:-ff0e::10:10:10}"
        printf 'Mode:      NAMESPACE (%s) [IPv6]\n' "${SERVER_NAME}"
        printf 'Status:    STREAMING (PID %s)\n' "$(cat "${PID_FILE6}")"
        printf 'Stream:    udp://[%s]:%s (pkt_size=%s, ttl=%s)\n' \
            "${grp6}" "${MCAST_PORT}" "${MPEGTS_PKT_SIZE}" "${MCAST_TTL}"
        printf 'Asset:     %s\n' "${MEDIA_FILE}"
    fi

    if (( running == 0 )); then
        printf 'Status:    STOPPED\n'
    fi
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
        local saved_proto saved_mcast saved_mcast6
        saved_proto="$(grep '^IP_VERSION=' "${STATE_DIR}/topology_state.env" 2>/dev/null | cut -d= -f2 | tr -d "'\"" || true)"
        saved_mcast="$(grep '^MCAST_GROUP=' "${STATE_DIR}/topology_state.env" 2>/dev/null | cut -d= -f2 | tr -d "'\"" || true)"
        saved_mcast6="$(grep '^MCAST_GROUP6=' "${STATE_DIR}/topology_state.env" 2>/dev/null | cut -d= -f2 | tr -d "'\"" || true)"
        [[ -n "${saved_proto}" ]] && IP_VERSION="${saved_proto}"
        [[ -n "${saved_mcast}" ]] && MCAST_GROUP="${saved_mcast}"
        [[ -n "${saved_mcast6}" ]] && MCAST_GROUP6="${saved_mcast6}"
    fi
    init_server_paths
    local mode="auto"
    local cmd=""

    while (( $# > 0 )); do
        case "$1" in
            -i|--interface|--iface)
                shift
                [[ $# -gt 0 ]] || die "Missing interface argument for $1"
                TARGET_IFACE="$1"
                mode="direct"
                shift
                ;;
            -d|--direct|--standalone)
                mode="direct"
                shift
                ;;
            -n|--netns|-c|--container)
                mode="netns"
                shift
                ;;
            -g|--group)
                shift
                [[ $# -gt 0 ]] || die "Missing group argument for $1"
                MCAST_GROUP="$1"
                shift
                ;;
            -p|--port)
                shift
                [[ $# -gt 0 ]] || die "Missing port argument for $1"
                MCAST_PORT="$1"
                shift
                ;;
            -4|--ipv4|--ip4)
                IP_VERSION="4"
                shift
                ;;
            -6|--ipv6|--ip6)
                IP_VERSION="6"
                if [[ "${MCAST_GROUP}" == "239.10.10.10" ]]; then
                    MCAST_GROUP="${MCAST_GROUP6:-ff0e::10:10:10}"
                fi
                shift
                ;;
            --dual|--dual-stack|-ds|-2)
                IP_VERSION="dual"
                shift
                ;;
            run|start|stop|status)
                cmd="$1"
                shift
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
    done

    if [[ "${IP_VERSION:-4}" != "dual" && "${IP_VERSION:-4}" != "dual-stack" && "${IP_VERSION:-4}" != "ds" ]]; then
        if [[ "${MCAST_GROUP}" =~ : || "${IP_VERSION:-4}" == "6" ]]; then
            IP_VERSION="6"
            if [[ "${MCAST_GROUP}" == "239.10.10.10" ]]; then
                MCAST_GROUP="${MCAST_GROUP6:-ff0e::10:10:10}"
            fi
        fi
    fi

    if [[ -z "${cmd}" ]]; then
        if [[ -t 0 ]]; then
            cmd="run"
        else
            cmd="start"
        fi
    fi

    if [[ "${cmd}" == "stop" ]]; then
        if [[ "${mode}" == "direct" ]]; then
            stop_direct_background
        elif [[ "${mode}" == "netns" ]]; then
            stop_background
        else
            stop_any
        fi
        return 0
    fi

    if [[ "${cmd}" == "status" ]]; then
        show_status
        return 0
    fi

    if [[ "${mode}" == "auto" ]]; then
        if is_pidfile_running "${DIRECT_PID_FILE}" || is_pidfile_running "${DIRECT_PID_FILE6}"; then
            mode="direct"
        elif netns_exists "${SERVER_NAME}"; then
            mode="netns"
        else
            local default_iface="${TARGET_IFACE:-${WAN_IF}}"
            if (( EUID == 0 )); then
                log_info "No namespace '${SERVER_NAME}' detected. Defaulting to direct host mode on ${default_iface}."
                mode="direct"
            else
                die "Namespace '${SERVER_NAME}' is not running.
To stream directly on physical interface '${default_iface}' without namespaces or topology:
  sudo ./scripts/start_server.sh -i ${default_iface} ${cmd}
To run with namespace topology:
  sudo ./scripts/setup.sh --wan-only (Deploy WAN side only)
  sudo ./scripts/setup.sh            (Deploy full lab topology)"
            fi
        fi
    fi

    case "${mode}:${cmd}" in
        direct:run)      run_direct_foreground ;;
        direct:start)    start_direct_background ;;
        netns:run)       run_foreground ;;
        netns:start)     start_background ;;
        *)               usage; exit 2 ;;
    esac
}

main "$@"
