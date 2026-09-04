#!/usr/bin/env bash
# ==============================================================================
# REAL IPTV MULTICAST TEST LAB - MEDIA SERVER (FFmpeg Streamer)
# Streams MPEG-TS video over UDP Multicast from inside SERVER_NAME container.
# Supports interactive running ('run') and background daemon ('start' / 'stop').
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
load_config

readonly PID_FILE="${STATE_DIR}/server.pid"
readonly LOG_FILE="${LOG_DIR}/server.log"

usage() {
    cat <<'USAGE'
Usage:
  ./scripts/start_server.sh [command]

Commands:
  run             Run streaming interactively in the foreground [Default if TTY]
  start           Run streaming in background daemon mode
  stop            Stop background streaming daemon
  status          Show status of media streaming daemon
USAGE
}

check_media_asset() {
    if [[ ! -f "${MEDIA_DIR}/${MEDIA_FILE}" ]]; then
        log_warn "Missing media asset ${MEDIA_DIR}/${MEDIA_FILE}."
        log_info "Auto-generating sample 1080p stream with scripts/generate_media.sh..."
        "${SCRIPT_DIR}/generate_media.sh"
    fi
}

run_foreground() {
    check_docker
    check_media_asset
    container_exists "${SERVER_NAME}" || die "Container '${SERVER_NAME}' is not running. Run ./scripts/setup.sh first."

    log_info "Streaming ${MCAST_GROUP}:${MCAST_PORT} from ${SERVER_NAME} (Foreground)..."
    docker exec "${SERVER_NAME}" ffmpeg -hide_banner -re -stream_loop -1 \
        -i "/media/${MEDIA_FILE}" -c copy -f mpegts \
        "udp://${MCAST_GROUP}:${MCAST_PORT}?pkt_size=${MPEGTS_PKT_SIZE}&ttl=${MCAST_TTL}"
}

start_background() {
    check_docker
    check_media_asset
    container_exists "${SERVER_NAME}" || die "Container '${SERVER_NAME}' is not running. Run ./scripts/setup.sh first."

    if is_pidfile_running "${PID_FILE}"; then
        log_warn "Media server already streaming (PID $(cat "${PID_FILE}"))."
        return 0
    fi

    log_info "Starting background media stream ${MCAST_GROUP}:${MCAST_PORT} from ${SERVER_NAME}..."
    nohup docker exec "${SERVER_NAME}" ffmpeg -hide_banner -re -stream_loop -1 \
        -i "/media/${MEDIA_FILE}" -c copy -f mpegts \
        "udp://${MCAST_GROUP}:${MCAST_PORT}?pkt_size=${MPEGTS_PKT_SIZE}&ttl=${MCAST_TTL}" \
        >"${LOG_FILE}" 2>&1 &

    local pid=$!
    printf '%s\n' "${pid}" > "${PID_FILE}"
    sleep 0.5

    if ! kill -0 "${pid}" 2>/dev/null; then
        log_error "Failed to start media server streaming."
        cat "${LOG_FILE}" >&2 || true
        rm -f "${PID_FILE}"
        return 1
    fi

    log_info "Media server streaming started [PID ${pid}]. Logs: ${LOG_FILE}"
}

stop_background() {
    if is_pidfile_running "${PID_FILE}"; then
        local pid
        pid="$(cat "${PID_FILE}")"
        log_info "Stopping media server streaming [PID ${pid}]..."
        stop_pidfile "${PID_FILE}"
    else
        rm -f "${PID_FILE}" 2>/dev/null || true
    fi

    # Terminate ffmpeg inside container
    docker exec "${SERVER_NAME}" pkill -TERM -f ffmpeg 2>/dev/null || true
    sleep 0.2
    docker exec "${SERVER_NAME}" pkill -KILL -f ffmpeg 2>/dev/null || true
    log_info "Media server streaming stopped."
}

show_status() {
    printf '== Media Server Status ==\n'
    if is_pidfile_running "${PID_FILE}"; then
        printf 'Status:  STREAMING (PID %s)\n' "$(cat "${PID_FILE}")"
        printf 'Stream:  udp://%s:%s (pkt_size=%s, ttl=%s)\n' "${MCAST_GROUP}" "${MCAST_PORT}" "${MPEGTS_PKT_SIZE}" "${MCAST_TTL}"
        printf 'Asset:   %s\n' "${MEDIA_FILE}"
    else
        printf 'Status:  STOPPED\n'
    fi
}

main() {
    load_config
    local cmd="${1:-}"

    if [[ -z "${cmd}" ]]; then
        if [[ -t 0 ]]; then
            cmd="run"
        else
            cmd="start"
        fi
    fi

    case "${cmd}" in
        run)    run_foreground ;;
        start)  start_background ;;
        stop)   stop_background ;;
        status) show_status ;;
        -h|--help) usage ;;
        *)      usage; exit 2 ;;
    esac
}

main "$@"
