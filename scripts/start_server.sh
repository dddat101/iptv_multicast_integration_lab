#!/usr/bin/env bash
# ==============================================================================
# REAL IPTV MULTICAST TEST LAB - MEDIA SERVER (FFmpeg Streamer)
# Streams MPEG-TS video over UDP Multicast.
# Supports two operating modes:
#   1. Direct Host Mode (--direct): Streams directly out physical WAN_IF with
#      optional direct WAN DHCP server (no Docker bridges/containers needed).
#   2. Container Mode (--container): Streams from inside SERVER_NAME container
#      attached to WAN test bridge.
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
load_config

readonly PID_FILE="${STATE_DIR}/server.pid"
readonly LOG_FILE="${LOG_DIR}/server.log"
readonly DIRECT_PID_FILE="${STATE_DIR}/server_direct.pid"
readonly DIRECT_LOG_FILE="${LOG_DIR}/server_direct.log"
readonly STATE_MODE_FILE="${STATE_DIR}/server_mode.txt"

usage() {
    cat <<'USAGE'
Usage:
  ./scripts/start_server.sh [options] [command]

Commands:
  run             Run streaming interactively in the foreground [Default if TTY]
  start           Run streaming in background daemon mode
  stop            Stop streaming daemon (direct or container)
  status          Show status of media streaming daemon

Options:
  -d, --direct, --standalone
                  Run directly on physical WAN_IF (no topology / Docker bridges needed)
  -c, --container Force running inside Docker container topology
  -h, --help      Show this help message

Examples:
  # Standalone WAN IPTV Server (Zero Topology):
  sudo ./scripts/start_server.sh --direct run
  sudo ./scripts/start_server.sh --direct start
  sudo ./scripts/start_server.sh stop

  # Container Topology Mode:
  ./scripts/start_server.sh start
  ./scripts/start_server.sh stop
USAGE
}

check_media_asset() {
    if [[ ! -f "${MEDIA_DIR}/${MEDIA_FILE}" ]]; then
        log_warn "Missing media asset ${MEDIA_DIR}/${MEDIA_FILE}."
        log_info "Auto-generating sample 1080p stream with scripts/generate_media.sh..."
        "${SCRIPT_DIR}/generate_media.sh"
    fi
}

# ------------------------------------------------------------------------------
# Container Topology Mode Functions
# ------------------------------------------------------------------------------
run_foreground() {
    check_docker
    check_media_asset
    container_exists "${SERVER_NAME}" || die "Container '${SERVER_NAME}' is not running. Run ./scripts/setup.sh first, or use --direct to stream on host."

    log_info "Streaming ${MCAST_GROUP}:${MCAST_PORT} from ${SERVER_NAME} (Foreground)..."
    docker exec "${SERVER_NAME}" ffmpeg -hide_banner -re -stream_loop -1 \
        -i "/media/${MEDIA_FILE}" -c copy -f mpegts \
        "udp://${MCAST_GROUP}:${MCAST_PORT}?pkt_size=${MPEGTS_PKT_SIZE}&ttl=${MCAST_TTL}"
}

start_background() {
    check_docker
    check_media_asset
    container_exists "${SERVER_NAME}" || die "Container '${SERVER_NAME}' is not running. Run ./scripts/setup.sh first, or use --direct to stream on host."

    if is_pidfile_running "${PID_FILE}"; then
        log_warn "Container media server already streaming (PID $(cat "${PID_FILE}"))."
        return 0
    fi

    log_info "Starting background media stream ${MCAST_GROUP}:${MCAST_PORT} from ${SERVER_NAME}..."
    nohup docker exec "${SERVER_NAME}" ffmpeg -hide_banner -re -stream_loop -1 \
        -i "/media/${MEDIA_FILE}" -c copy -f mpegts \
        "udp://${MCAST_GROUP}:${MCAST_PORT}?pkt_size=${MPEGTS_PKT_SIZE}&ttl=${MCAST_TTL}" \
        >"${LOG_FILE}" 2>&1 &

    local pid=$!
    printf '%s\n' "${pid}" > "${PID_FILE}"
    printf 'container\n' > "${STATE_MODE_FILE}"
    sleep 0.5

    if ! kill -0 "${pid}" 2>/dev/null; then
        log_error "Failed to start media server streaming in container."
        cat "${LOG_FILE}" >&2 || true
        rm -f "${PID_FILE}"
        return 1
    fi

    log_info "Container media server streaming started [PID ${pid}]. Logs: ${LOG_FILE}"
}

stop_background() {
    if is_pidfile_running "${PID_FILE}"; then
        local pid
        pid="$(cat "${PID_FILE}")"
        log_info "Stopping container media server streaming [PID ${pid}]..."
        stop_pidfile "${PID_FILE}"
    else
        rm -f "${PID_FILE}" 2>/dev/null || true
    fi

    if container_exists "${SERVER_NAME}"; then
        docker exec "${SERVER_NAME}" pkill -TERM -f ffmpeg 2>/dev/null || true
        sleep 0.2
        docker exec "${SERVER_NAME}" pkill -KILL -f ffmpeg 2>/dev/null || true
    fi
    log_info "Container media server streaming stopped."
}

# ------------------------------------------------------------------------------
# Direct Standalone WAN Mode Functions
# ------------------------------------------------------------------------------
run_direct_foreground() {
    require_root
    check_media_asset
    configure_direct_wan_interface "${WAN_IF}" "${SERVER_IP}"

    if [[ "${ENABLE_WAN_DHCP:-0}" == "1" ]]; then
        direct_wan_dhcp_server start "${WAN_IF}"
    fi

    local local_ip="${SERVER_IP%/*}"
    log_info "Streaming ${MCAST_GROUP}:${MCAST_PORT} directly on ${WAN_IF} (Foreground)..."
    log_info "Press Ctrl+C to terminate streaming."

    if command -v ffmpeg >/dev/null 2>&1; then
        ffmpeg -hide_banner -re -stream_loop -1 \
            -i "${MEDIA_DIR}/${MEDIA_FILE}" -c copy -f mpegts \
            "udp://${MCAST_GROUP}:${MCAST_PORT}?pkt_size=${MPEGTS_PKT_SIZE}&ttl=${MCAST_TTL}&localaddr=${local_ip}"
    else
        check_docker
        docker run -it --rm --net=host -v "${MEDIA_DIR}:/media:ro" "${MEDIA_IMAGE}" \
            ffmpeg -hide_banner -re -stream_loop -1 \
            -i "/media/${MEDIA_FILE}" -c copy -f mpegts \
            "udp://${MCAST_GROUP}:${MCAST_PORT}?pkt_size=${MPEGTS_PKT_SIZE}&ttl=${MCAST_TTL}&localaddr=${local_ip}"
    fi
}

start_direct_background() {
    require_root
    check_media_asset

    if is_pidfile_running "${DIRECT_PID_FILE}"; then
        log_warn "Direct media server already streaming on ${WAN_IF} (PID $(cat "${DIRECT_PID_FILE}"))."
        return 0
    fi

    configure_direct_wan_interface "${WAN_IF}" "${SERVER_IP}"

    if [[ "${ENABLE_WAN_DHCP:-0}" == "1" ]]; then
        direct_wan_dhcp_server start "${WAN_IF}"
    fi

    log_info "Starting direct background media stream ${MCAST_GROUP}:${MCAST_PORT} on ${WAN_IF}..."
    local local_ip="${SERVER_IP%/*}"
    local pid

    if command -v ffmpeg >/dev/null 2>&1; then
        nohup ffmpeg -hide_banner -re -stream_loop -1 \
            -i "${MEDIA_DIR}/${MEDIA_FILE}" -c copy -f mpegts \
            "udp://${MCAST_GROUP}:${MCAST_PORT}?pkt_size=${MPEGTS_PKT_SIZE}&ttl=${MCAST_TTL}&localaddr=${local_ip}" \
            >"${DIRECT_LOG_FILE}" 2>&1 &
        pid=$!
    else
        check_docker
        nohup docker run --rm --net=host -v "${MEDIA_DIR}:/media:ro" "${MEDIA_IMAGE}" \
            ffmpeg -hide_banner -re -stream_loop -1 \
            -i "/media/${MEDIA_FILE}" -c copy -f mpegts \
            "udp://${MCAST_GROUP}:${MCAST_PORT}?pkt_size=${MPEGTS_PKT_SIZE}&ttl=${MCAST_TTL}&localaddr=${local_ip}" \
            >"${DIRECT_LOG_FILE}" 2>&1 &
        pid=$!
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

    log_info "Direct media server streaming started on ${WAN_IF} [PID ${pid}]. Logs: ${DIRECT_LOG_FILE}"
}

stop_direct_background() {
    require_root
    if is_pidfile_running "${DIRECT_PID_FILE}"; then
        local pid
        pid="$(cat "${DIRECT_PID_FILE}")"
        log_info "Stopping direct media server streaming [PID ${pid}]..."
        stop_pidfile "${DIRECT_PID_FILE}"
    else
        rm -f "${DIRECT_PID_FILE}" 2>/dev/null || true
    fi

    # Terminate any stray host ffmpeg streaming to MCAST_GROUP:MCAST_PORT
    pkill -f "udp://${MCAST_GROUP}:${MCAST_PORT}" 2>/dev/null || true

    if [[ "${ENABLE_WAN_DHCP:-0}" == "1" ]]; then
        direct_wan_dhcp_server stop 2>/dev/null || true
    fi

    cleanup_direct_wan_interface "${WAN_IF}"
    rm -f "${STATE_MODE_FILE}" 2>/dev/null || true
    log_info "Direct media server streaming and WAN interface stopped."
}

stop_any() {
    local stopped=0
    if is_pidfile_running "${DIRECT_PID_FILE}" || [[ -f "${STATE_MODE_FILE}" && "$(cat "${STATE_MODE_FILE}" 2>/dev/null)" == "direct" ]]; then
        stop_direct_background
        stopped=1
    fi
    if is_pidfile_running "${PID_FILE}" || container_exists "${SERVER_NAME}"; then
        stop_background
        stopped=1
    fi
    if (( stopped == 0 )); then
        rm -f "${DIRECT_PID_FILE}" "${PID_FILE}" "${STATE_MODE_FILE}" 2>/dev/null || true
        log_info "Media server streaming is already stopped."
    fi
}

show_status() {
    printf '== Media Server Status ==\n'
    local running=0

    if is_pidfile_running "${DIRECT_PID_FILE}"; then
        running=1
        printf 'Mode:    DIRECT HOST (Zero Topology on %s)\n' "${WAN_IF}"
        printf 'Status:  STREAMING (PID %s)\n' "$(cat "${DIRECT_PID_FILE}")"
        printf 'Stream:  udp://%s:%s (pkt_size=%s, ttl=%s, localaddr=%s)\n' \
            "${MCAST_GROUP}" "${MCAST_PORT}" "${MPEGTS_PKT_SIZE}" "${MCAST_TTL}" "${SERVER_IP%/*}"
        printf 'Asset:   %s\n' "${MEDIA_FILE}"
        printf 'WAN IP:  %s\n' "$(ip -4 -o addr show dev "${WAN_IF}" 2>/dev/null | awk '{print $4}' | head -n1 || echo '<none>')"
        direct_wan_dhcp_server status || true
    fi

    if is_pidfile_running "${PID_FILE}"; then
        running=1
        printf 'Mode:    CONTAINER (%s)\n' "${SERVER_NAME}"
        printf 'Status:  STREAMING (PID %s)\n' "$(cat "${PID_FILE}")"
        printf 'Stream:  udp://%s:%s (pkt_size=%s, ttl=%s)\n' \
            "${MCAST_GROUP}" "${MCAST_PORT}" "${MPEGTS_PKT_SIZE}" "${MCAST_TTL}"
        printf 'Asset:   %s\n' "${MEDIA_FILE}"
    fi

    if (( running == 0 )); then
        printf 'Status:  STOPPED\n'
    fi
}

main() {
    load_config
    local mode="auto"
    local cmd=""

    while (( $# > 0 )); do
        case "$1" in
            -d|--direct|--standalone) mode="direct"; shift ;;
            -c|--container)          mode="container"; shift ;;
            run|start|stop|status)   cmd="$1"; shift ;;
            -h|--help)               usage; exit 0 ;;
            *)                       usage; exit 2 ;;
        esac
    done

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
        elif [[ "${mode}" == "container" ]]; then
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
        if is_pidfile_running "${DIRECT_PID_FILE}"; then
            mode="direct"
        elif container_exists "${SERVER_NAME}"; then
            mode="container"
        else
            if (( EUID == 0 )); then
                log_info "No container '${SERVER_NAME}' detected. Defaulting to direct WAN host mode on ${WAN_IF}."
                mode="direct"
            else
                die "Container '${SERVER_NAME}' is not running.
To stream directly on physical interface '${WAN_IF}' without containers or topology:
  sudo ./scripts/start_server.sh --direct ${cmd}
  (or: sudo ./scripts/start_wan_server.sh ${cmd})
To run with container topology:
  sudo ./scripts/setup.sh --wan-only (Deploy WAN side only)
  sudo ./scripts/setup.sh            (Deploy full lab topology)"
            fi
        fi
    fi

    case "${mode}:${cmd}" in
        direct:run)      run_direct_foreground ;;
        direct:start)    start_direct_background ;;
        container:run)   run_foreground ;;
        container:start) start_background ;;
        *)               usage; exit 2 ;;
    esac
}

main "$@"
