#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/scripts/lib/common.sh"
load_config
require_cmd docker
log_info "Building ${MEDIA_IMAGE} from Dockerfile.media..."
docker build -f "${ROOT}/Dockerfile.media" -t "${MEDIA_IMAGE}" "${ROOT}"
log_info "Successfully built ${MEDIA_IMAGE}"
