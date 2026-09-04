#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/scripts/lib/common.sh"
load_config
require_cmd ffmpeg
out="${MEDIA_DIR}/${MEDIA_FILE}"
log_info "Generating 120s sample MPEG-TS video (1080p, 8Mbps) to ${out}..."
ffmpeg -hide_banner -y \
  -f lavfi -i testsrc2=size=1920x1080:rate=30 \
  -f lavfi -i sine=frequency=1000:sample_rate=48000 \
  -t 120 \
  -c:v libx264 -preset veryfast -profile:v high -level 4.1 \
  -b:v 8M -maxrate 8M -bufsize 16M -g 60 \
  -c:a aac -b:a 128k \
  -f mpegts "${out}"
log_info "Sample video successfully created: ${out} ($(stat -c %s "${out}" 2>/dev/null || echo '?') bytes)"
