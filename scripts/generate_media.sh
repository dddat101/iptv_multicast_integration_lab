#!/usr/bin/env bash
# ==============================================================================
# REAL IPTV MULTICAST TEST LAB - MEDIA ASSET GENERATOR
# ==============================================================================
# Generates standards-compliant MPEG-TS multicast test assets with customizable:
#  - Bitrate, resolution, duration, FPS, codec presets
#  - Synthetic video patterns (testsrc2, testsrc, smptebars, etc.)
#  - Image slideshow input (folder of PNG/JPG/WEBP/BMP images)
#  - Audio input (folder of audio tracks or single audio file MP3/WAV/AAC)
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/scripts/lib/common.sh"
load_config
require_cmd ffmpeg

# Default Parameters
OUT_FILE="${MEDIA_DIR}/${MEDIA_FILE}"
DURATION=120
RESOLUTION="1920x1080"
BITRATE="8M"
FPS="30"
PATTERN="testsrc2"
VCODEC="libx264"
PRESET="veryfast"
ACODEC="aac"
ABITRATE="128k"
MPEGTS_CONTAINER="mpegts"
IMAGE_DIR=""
IMAGE_DURATION="3"
AUDIO_INPUT=""
NO_AUDIO=0
SINE_FREQ="1000"

# Multi-channel batch parameters
CHANNELS_COUNT=0
CHANNEL_ID=0
CHANNEL_PREFIX="channel_"
MCAST_BASE="239.100.1."
PARALLEL_JOBS=4

TMP_DIR=""
cleanup() {
    if [[ -n "${TMP_DIR:-}" && -d "${TMP_DIR}" ]]; then
        rm -rf "${TMP_DIR}"
    fi
}
trap cleanup EXIT INT TERM

usage() {
    cat <<'EOF'
Usage:
  ./scripts/generate_media.sh [options]

Quick Presets:
  --preset-low, -low        Low-RAM lightweight stream: 640x360, 1 Mbps, 25 fps
                            (Recommended for testing 32 concurrent channels)
  --preset-medium, -med     Standard HD stream: 1280x720, 4 Mbps, 30 fps
  --preset-high, -high      Full HD stream: 1920x1080, 8 Mbps, 30 fps (Default)
  --preset-4k               Ultra HD stream: 3840x2160, 20 Mbps, 30 fps

Multi-Channel Generation (1 -> N):
  -n, --count, --channels <N>
                            Generate N distinct channel videos (1 -> N).
                            Each video displays channel number, multicast IP, timecode,
                            and unique color gradient & audio frequency.
      --channel-id <i>      Generate video for a single specific channel i
      --prefix <prefix>     Filename prefix (default: channel_ -> channel_1.ts, ...)
      --multicast-base <IP> Base multicast IP prefix (default: 239.100.1.)
  -j, --jobs, --parallel <N>
                            Number of parallel rendering workers (default: 4)

General Options:
  -o, --output <path>       Output file path or filename (default: media/sample_1080p_8mbps.ts)
  -t, -d, --duration <sec>  Video duration in seconds (default: 120)
  -r, --resolution <res>    Resolution (e.g. 1920x1080, 1280x720, 640x360, 1080p, 720p, 480p, 360p, 4k)
  -b, --bitrate <rate>      Video bitrate (e.g. 8M, 4M, 1M, 500k, default: 8M)
  -f, --fps <fps>           Frames per second (e.g. 25, 30, 60, default: 30)
  -p, --pattern <name>      Synthetic pattern when not using images (testsrc2, testsrc, smptebars, default: testsrc2)
      --preset <speed>      x264 encoding preset (ultrafast, veryfast, medium, default: veryfast)

Custom Media Inputs:
  -i, --images, --image-dir <dir>
                            Folder containing images (.jpg, .png, .bmp, .webp) for slideshow
      --image-duration <sec>
                            Display duration per image in seconds (default: 3)
  -a, --audio, --audio-dir, --audio-file <path>
                            Folder containing audio tracks or a single audio file (.mp3, .wav, .aac, etc.)
      --no-audio            Disable audio stream in output (-an)
      --audio-bitrate <rate>
                            Audio bitrate (default: 128k)

Other:
  -h, --help                Show this help message

Examples:
  # 1. Default backward-compatible 1080p 8Mbps stream:
  ./scripts/generate_media.sh

  # 2. Generate 32 channel videos (channel_1.ts -> channel_32.ts) with visual effects:
  ./scripts/generate_media.sh -n 32 --preset-low -d 120

  # 3. Generate 10 HD channels (720p, 2Mbps):
  ./scripts/generate_media.sh -n 10 -r 720p -b 2M -d 60 -j 6

  # 4. Generate lightweight 1Mbps video to save RAM for 32 groups:
  ./scripts/generate_media.sh --preset-low

  # 5. Generate video from an image folder with custom audio:
  ./scripts/generate_media.sh -i /path/to/images -a /path/to/music.mp3 -o slideshow.ts
EOF
}

parse_resolution() {
    case "${1,,}" in
        1080p|fhd|1080) echo "1920x1080" ;;
        720p|hd|720)   echo "1280x720" ;;
        480p|sd|480)   echo "854x480" ;;
        360p|low|360)  echo "640x360" ;;
        4k|uhd|2160p|2160) echo "3840x2160" ;;
        *x*)           echo "$1" ;;
        *)
            die "Invalid resolution: '$1'. Use WIDTHxHEIGHT (e.g. 1280x720) or preset (1080p, 720p, 480p, 360p, 4k)."
            ;;
    esac
}

calc_bufsize() {
    local rate="$1"
    if [[ "${rate}" =~ ^([0-9]+)([kKmM])$ ]]; then
        local num="${BASH_REMATCH[1]}"
        local unit="${BASH_REMATCH[2]}"
        local double=$(( num * 2 ))
        echo "${double}${unit}"
    else
        echo "${rate}"
    fi
}

collect_images() {
    local dir="$1"
    local target_w="$2"
    local target_h="$3"
    [[ -d "${dir}" ]] || die "Image directory not found: ${dir}"

    local raw_imgs=()
    while IFS= read -r -d '' file; do
        raw_imgs+=("${file}")
    done < <(find -L "${dir}" -maxdepth 2 -type f \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" -o -iname "*.bmp" -o -iname "*.webp" \) -print0 | sort -z)

    ((${#raw_imgs[@]} > 0)) || die "No image files found in ${dir} (*.jpg, *.png, *.bmp, *.webp)"

    log_info "Normalizing ${#raw_imgs[@]} images to ${target_w}x${target_h}..." >&2
    local norm_dir="${TMP_DIR}/norm_images"
    mkdir -p "${norm_dir}"

    local idx=1
    local pids=()
    local max_jobs=8
    local norm_imgs=()

    for img in "${raw_imgs[@]}"; do
        local out_norm="${norm_dir}/frame_$(printf '%05d' "${idx}").png"
        norm_imgs+=("${out_norm}")
        ffmpeg -hide_banner -loglevel error -y -i "${img}" \
            -vf "scale=${target_w}:${target_h}:force_original_aspect_ratio=decrease,pad=${target_w}:${target_h}:(ow-iw)/2:(oh-ih)/2:black,format=yuv420p" \
            "${out_norm}" &
        pids+=($!)
        ((idx++))

        if (( ${#pids[@]} >= max_jobs )); then
            wait "${pids[0]}" 2>/dev/null || true
            pids=("${pids[@]:1}")
        fi
    done
    wait "${pids[@]}" 2>/dev/null || true

    local concat_file="${TMP_DIR}/images_concat.txt"
    : > "${concat_file}"

    for nimg in "${norm_imgs[@]}"; do
        printf "file '%s'\n" "${nimg}" >> "${concat_file}"
        printf "duration %s\n" "${IMAGE_DURATION}" >> "${concat_file}"
    done
    # Last image repeated without duration as per concat demuxer spec
    printf "file '%s'\n" "${norm_imgs[-1]}" >> "${concat_file}"

    echo "${concat_file}"
}

collect_audio() {
    local path="$1"
    if [[ -f "${path}" ]]; then
        echo "file:${path}"
        return 0
    fi
    if [[ -d "${path}" ]]; then
        local audio_list=()
        while IFS= read -r -d '' file; do
            audio_list+=("${file}")
        done < <(find -L "${path}" -maxdepth 2 -type f \( -iname "*.mp3" -o -iname "*.wav" -o -iname "*.aac" -o -iname "*.m4a" -o -iname "*.flac" -o -iname "*.ogg" \) -print0 | sort -z)

        if ((${#audio_list[@]} == 0)); then
            log_warn "No audio files found in ${path}. Falling back to synthetic tone." >&2
            echo "synthetic"
            return 0
        fi

        local concat_file="${TMP_DIR}/audio_concat.txt"
        : > "${concat_file}"
        for aud in "${audio_list[@]}"; do
            local escaped_path="${aud//\'/\'\\\'\'}"
            printf "file '%s'\n" "${escaped_path}" >> "${concat_file}"
        done
        echo "concat:${concat_file}"
        return 0
    fi
    die "Audio path does not exist: ${path}"
}

get_channel_theme() {
    local ch="$1"
    local themes=(
        "0x1a2a6c:0xb21f1f:0xfdbb2d:radial"     # 1: Midnight Fire
        "0x0f2027:0x203a43:0x2c5364:linear"     # 2: Dark Slate & Teal
        "0x4a00e0:0x8e2de2:0xf77737:spiral"     # 3: Neon Purple & Orange
        "0x000428:0x004e92:0x00c6ff:radial"     # 4: Ocean Blue
        "0xfa709a:0xfee140:0x30cfd0:circular"   # 5: Cyber Sunset
        "0x051937:0x004d7a:0x008793:linear"     # 6: Deep Emerald & Sea
        "0xee0979:0xff6a00:0xf7971e:radial"     # 7: Crimson Flame
        "0x2b5876:0x4e4376:0x6a11cb:spiral"     # 8: Royal Violet
        "0x11998e:0x38ef7d:0x0575e6:circular"   # 9: Neon Lime & Cyan
        "0x8a2387:0xe94057:0xf27121:radial"     # 10: Sunset Glow
        "0x1f4037:0x99f2c8:0x2c3e50:linear"     # 11: Mint Forest
        "0xd31027:0xea384d:0xf45c43:spiral"     # 12: Ruby Red
        "0x16222a:0x3a6073:0x4ca1af:radial"     # 13: Steel Blue
        "0x4776e6:0x8e54e9:0xff5858:circular"   # 14: Electric Berry
        "0x0052d4:0x4364f7:0x6fb1fc:linear"     # 15: Deep Sky Blue
        "0x654ea3:0xeaafc8:0x5b247a:spiral"     # 16: Lavender Dream
        "0x3a1c71:0xd76d77:0xffaf7b:radial"     # 17: Twilight Peach
        "0x134e5e:0x71b280:0x2b580c:circular"   # 18: Pine & Jade
        "0x59c173:0xa17fe0:0x5d26c1:linear"     # 19: Spring Aurora
        "0x0b8793:0x360033:0x0b8793:spiral"     # 20: Cyber Punk
        "0xeb3349:0xf45c43:0xffba10:radial"     # 21: Fiery Amber
        "0x1d2b64:0xf8cdda:0x480048:circular"   # 22: Retro Wave
        "0x00b4db:0x0083b0:0x00416a:linear"     # 23: Cobalt Wave
        "0x780206:0x061161:0x2c3e50:spiral"     # 24: Wine & Navy
        "0x141e30:0x243b55:0x3a6073:radial"     # 25: Night Shadow
        "0xa8ff78:0x78ffd6:0x007991:circular"   # 26: Toxic Mint
        "0xed213a:0x93291e:0x000000:linear"     # 27: Blood Moon
        "0x396afc:0x2948ff:0x1b1464:spiral"     # 28: Laser Indigo
        "0xf857a6:0xff5858:0xfda085:radial"     # 29: Hot Pink Fusion
        "0x2193b0:0x6dd5ed:0xb993d6:circular"   # 30: Frozen Lake
        "0x1e130c:0x9a8478:0x43281c:linear"     # 31: Desert Espresso
        "0x0f0c29:0x302b63:0x24243e:spiral"     # 32: Deep Cosmos
    )
    local idx=$(( (ch - 1) % ${#themes[@]} ))
    echo "${themes[idx]}"
}

render_channel_video() {
    local ch="$1"
    local total="$2"
    local out_path="$3"
    local res_w="$4"
    local res_h="$5"
    local buf_size="$6"
    local gop="$7"
    local img_concat="$8"
    shift 8
    local aud_input_args=("$@")

    local mcast_ip="${MCAST_BASE}${ch}:${MCAST_PORT:-5000}"
    local theme
    theme="$(get_channel_theme "${ch}")"
    local c0="${theme%%:*}"
    local rest="${theme#*:}"
    local c1="${rest%%:*}"
    local rest2="${rest#*:}"
    local c2="${rest2%%:*}"
    local gtype="${rest2#*:}"

    local pad_fmt="%02d"
    if (( total >= 100 )); then
        pad_fmt="%03d"
    fi
    local ch_num_padded
    printf -v ch_num_padded "${pad_fmt}" "${ch}"

    local top_h=$(( res_h * 36 / 360 ))
    local bottom_h=$(( res_h * 34 / 360 ))
    local box_w=$(( res_w * 360 / 640 ))
    local box_h=$(( res_h * 150 / 360 ))
    local fs_title=$(( res_h * 18 / 360 ))
    local fs_badge=$(( res_h * 16 / 360 ))
    local fs_ch=$(( res_h * 50 / 360 ))
    local fs_ip=$(( res_h * 24 / 360 ))
    local fs_bar=$(( res_h * 16 / 360 ))

    local audio_freq=$(( 400 + ((ch - 1) % 32) * 25 ))
    local corner_len=$(( res_h * 20 / 360 ))
    local corner_thick=$(( res_h * 3 / 360 ))
    (( corner_thick >= 2 )) || corner_thick=2
    local glow_thick=$(( res_h * 4 / 360 ))
    (( glow_thick >= 2 )) || glow_thick=2
    local glow_offset=$(( res_h * 6 / 360 ))
    local scan_w=$(( res_w * 60 / 640 ))
    local scan_h=$(( res_h * 2 / 360 ))
    (( scan_h >= 2 )) || scan_h=2

    local vf_filter="drawbox=x=0:y=0:w=iw:h=${top_h}:color=black@0.7:t=fill,\
drawtext=text='IPTV TEST LAB  •  CH ${ch_num_padded}':fontsize=${fs_title}:fontcolor=white:x=15:y=$(( top_h / 4 )),\
drawtext=text='${RESOLUTION} | ${BITRATE}':fontsize=${fs_badge}:fontcolor=yellow:x=w-text_w-15:y=$(( top_h / 4 )),\
drawbox=x='(iw-w)/2':y='(ih-h)/2':w='${box_w}+${glow_offset}*2+4*sin(4*t)':h='${box_h}+${glow_offset}*2+4*sin(4*t)':color=cyan@0.35:t=${glow_thick},\
drawbox=x='(iw-${box_w})/2':y='(ih-${box_h})/2':w=${box_w}:h=${box_h}:color=black@0.75:t=fill,\
drawbox=x='(iw-${box_w})/2':y='(ih-${box_h})/2':w=${box_w}:h=${box_h}:color=white@0.85:t=2,\
drawbox=x='(iw-${box_w})/2':y='(ih-${box_h})/2':w=${corner_len}:h=${corner_thick}:color=yellow@0.9:t=fill,\
drawbox=x='(iw-${box_w})/2':y='(ih-${box_h})/2':w=${corner_thick}:h=${corner_len}:color=yellow@0.9:t=fill,\
drawbox=x='(iw+${box_w})/2-${corner_len}':y='(ih-${box_h})/2':w=${corner_len}:h=${corner_thick}:color=yellow@0.9:t=fill,\
drawbox=x='(iw+${box_w})/2-${corner_thick}':y='(ih-${box_h})/2':w=${corner_thick}:h=${corner_len}:color=yellow@0.9:t=fill,\
drawbox=x='(iw-${box_w})/2':y='(ih+${box_h})/2-${corner_thick}':w=${corner_len}:h=${corner_thick}:color=yellow@0.9:t=fill,\
drawbox=x='(iw-${box_w})/2':y='(ih+${box_h})/2-${corner_len}':w=${corner_thick}:h=${corner_len}:color=yellow@0.9:t=fill,\
drawbox=x='(iw+${box_w})/2-${corner_len}':y='(ih+${box_h})/2-${corner_thick}':w=${corner_len}:h=${corner_thick}:color=yellow@0.9:t=fill,\
drawbox=x='(iw+${box_w})/2-${corner_thick}':y='(ih+${box_h})/2-${corner_len}':w=${corner_thick}:h=${corner_len}:color=yellow@0.9:t=fill,\
drawbox=x='(iw-${box_w})/2 + 10 + mod(t*220, ${box_w}-80)':y='(ih)/2+14':w=${scan_w}:h=${scan_h}:color=cyan@0.9:t=fill,\
drawtext=text='● LIVE':fontsize=$(( fs_badge * 8 / 10 )):fontcolor=red:x='(w-${box_w})/2+14':y='(h-${box_h})/2+12':enable='mod(floor(t*2),2)',\
drawtext=text='STATUS\: ACTIVE':fontsize=$(( fs_badge * 75 / 100 )):fontcolor=lime:x='(w+${box_w})/2-text_w-14':y='(h-${box_h})/2+12',\
drawtext=text='CHANNEL ${ch_num_padded}':fontsize=${fs_ch}:fontcolor=white:x=(w-text_w)/2:y=(h-text_h)/2-$(( box_h / 7 )),\
drawtext=text='${mcast_ip}':fontsize=${fs_ip}:fontcolor=cyan:x=(w-text_w)/2:y=(h-text_h)/2+$(( box_h / 4 )),\
drawbox=x=0:y=ih-${bottom_h}:w=iw:h=${bottom_h}:color=black@0.75:t=fill,\
drawtext=text='PTS\: %{pts\:hms}':fontsize=${fs_bar}:fontcolor=white:x=15:y=h-$(( bottom_h * 3 / 4 )),\
drawtext=text='FRAME\: %{n}':fontsize=${fs_bar}:fontcolor=lime:x=w-text_w-15:y=h-$(( bottom_h * 3 / 4 )),\
format=yuv420p"

    local ch_ffmpeg_args=(-hide_banner -loglevel error -y)

    # Video input: either user image slideshow or channel-specific gradient
    if [[ -n "${img_concat:-}" && -f "${img_concat:-}" ]]; then
        ch_ffmpeg_args+=(-stream_loop -1 -f concat -safe 0 -i "${img_concat}")
    else
        ch_ffmpeg_args+=(-f lavfi -i "gradients=s=${RESOLUTION}:r=${FPS}:nb_colors=3:c0=${c0}:c1=${c1}:c2=${c2}:speed=0.03:type=${gtype}")
    fi

    # Audio input: either user audio or channel-specific sine frequency
    if (( NO_AUDIO == 1 )); then
        :
    elif (( ${#aud_input_args[@]} > 0 )); then
        ch_ffmpeg_args+=("${aud_input_args[@]}")
    else
        ch_ffmpeg_args+=(-f lavfi -i "sine=frequency=${audio_freq}:sample_rate=48000")
    fi

    local ch_output_opts=(-vf "${vf_filter}" -r "${FPS}")
    if (( NO_AUDIO == 1 )); then
        ch_output_opts+=(-an)
    else
        ch_output_opts+=(-c:a "${ACODEC}" -b:a "${ABITRATE}")
    fi

    ch_output_opts+=(
        -t "${DURATION}"
        -c:v "${VCODEC}"
        -preset "${PRESET}"
        -b:v "${BITRATE}"
        -maxrate "${BITRATE}"
        -bufsize "${buf_size}"
        -g "${gop}"
        -f "${MPEGTS_CONTAINER}"
        "${out_path}"
    )

    ch_ffmpeg_args+=("${ch_output_opts[@]}")
    ffmpeg "${ch_ffmpeg_args[@]}"
}

main() {
    while (( $# > 0 )); do
        case "$1" in
            --preset-low|-low)
                RESOLUTION="640x360"
                BITRATE="1M"
                ABITRATE="64k"
                FPS="25"
                PRESET="ultrafast"
                OUT_FILE="${MEDIA_DIR}/sample_low_1mbps.ts"
                shift
                ;;
            --preset-med|--preset-medium|-med)
                RESOLUTION="1280x720"
                BITRATE="4M"
                ABITRATE="128k"
                FPS="30"
                PRESET="veryfast"
                OUT_FILE="${MEDIA_DIR}/sample_720p_4mbps.ts"
                shift
                ;;
            --preset-high|-high)
                RESOLUTION="1920x1080"
                BITRATE="8M"
                ABITRATE="128k"
                FPS="30"
                PRESET="veryfast"
                OUT_FILE="${MEDIA_DIR}/${MEDIA_FILE}"
                shift
                ;;
            --preset-4k)
                RESOLUTION="3840x2160"
                BITRATE="20M"
                ABITRATE="192k"
                FPS="30"
                PRESET="veryfast"
                OUT_FILE="${MEDIA_DIR}/sample_4k_20mbps.ts"
                shift
                ;;
            -o|--output)
                shift
                [[ $# -gt 0 ]] || die "Missing argument for $1"
                OUT_FILE="$1"
                shift
                ;;
            -t|-d|--duration)
                shift
                [[ $# -gt 0 ]] || die "Missing argument for $1"
                DURATION="$1"
                shift
                ;;
            -r|--resolution)
                shift
                [[ $# -gt 0 ]] || die "Missing argument for $1"
                RESOLUTION="$(parse_resolution "$1")"
                shift
                ;;
            -b|--bitrate)
                shift
                [[ $# -gt 0 ]] || die "Missing argument for $1"
                BITRATE="$1"
                shift
                ;;
            -f|--fps)
                shift
                [[ $# -gt 0 ]] || die "Missing argument for $1"
                FPS="$1"
                shift
                ;;
            -p|--pattern)
                shift
                [[ $# -gt 0 ]] || die "Missing argument for $1"
                PATTERN="$1"
                shift
                ;;
            --preset)
                shift
                [[ $# -gt 0 ]] || die "Missing argument for $1"
                PRESET="$1"
                shift
                ;;
            -i|--images|--image-dir)
                shift
                [[ $# -gt 0 ]] || die "Missing argument for $1"
                IMAGE_DIR="$1"
                shift
                ;;
            --image-duration)
                shift
                [[ $# -gt 0 ]] || die "Missing argument for $1"
                IMAGE_DURATION="$1"
                shift
                ;;
            -a|--audio|--audio-dir|--audio-file)
                shift
                [[ $# -gt 0 ]] || die "Missing argument for $1"
                AUDIO_INPUT="$1"
                shift
                ;;
            --no-audio)
                NO_AUDIO=1
                shift
                ;;
            --audio-bitrate|--abitrate)
                shift
                [[ $# -gt 0 ]] || die "Missing argument for $1"
                ABITRATE="$1"
                shift
                ;;
            -n|--count|--channels)
                shift
                [[ $# -gt 0 ]] || die "Missing argument for $1"
                CHANNELS_COUNT="$1"
                shift
                ;;
            --channel-id)
                shift
                [[ $# -gt 0 ]] || die "Missing argument for $1"
                CHANNEL_ID="$1"
                shift
                ;;
            --prefix|--channel-prefix)
                shift
                [[ $# -gt 0 ]] || die "Missing argument for $1"
                CHANNEL_PREFIX="$1"
                shift
                ;;
            --multicast-base|--mcast-base)
                shift
                [[ $# -gt 0 ]] || die "Missing argument for $1"
                MCAST_BASE="$1"
                shift
                ;;
            -j|--jobs|--parallel)
                shift
                [[ $# -gt 0 ]] || die "Missing argument for $1"
                PARALLEL_JOBS="$1"
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "Unknown option: $1. Run ./scripts/generate_media.sh --help for usage."
                ;;
        esac
    done

    # Resolve output path
    if [[ "${OUT_FILE}" != /* && "${OUT_FILE}" != ./* && "${OUT_FILE}" != ../* ]]; then
        OUT_FILE="${MEDIA_DIR}/${OUT_FILE}"
    fi
    mkdir -p "$(dirname "${OUT_FILE}")"

    # Setup temp directory for lists
    TMP_DIR="$(mktemp -d -t iptv_media_gen_XXXXXX)"

    local res_w="${RESOLUTION%x*}"
    local res_h="${RESOLUTION#*x}"
    local buf_size
    buf_size="$(calc_bufsize "${BITRATE}")"
    local gop=$(( FPS * 2 ))

    if (( CHANNELS_COUNT > 0 || CHANNEL_ID > 0 )); then
        local start_ch=1
        local end_ch="${CHANNELS_COUNT}"
        if (( CHANNEL_ID > 0 && CHANNELS_COUNT == 0 )); then
            start_ch="${CHANNEL_ID}"
            end_ch="${CHANNEL_ID}"
        fi

        log_info "=================================================================="
        log_info "      IPTV MULTI-CHANNEL VIDEO GENERATION (Channels ${start_ch} -> ${end_ch})"
        log_info "=================================================================="
        log_info "Target Directory: ${MEDIA_DIR}"
        log_info "File Pattern:     ${CHANNEL_PREFIX}{${start_ch}..${end_ch}}.ts"
        log_info "Resolution:       ${RESOLUTION} (${res_w}x${res_h})"
        log_info "Framerate:        ${FPS} fps (GOP=${gop})"
        log_info "Bitrate:          ${BITRATE} (preset: ${PRESET})"
        log_info "Duration:         ${DURATION} seconds per channel"
        log_info "Multicast Base:   ${MCAST_BASE}{${start_ch}..${end_ch}}:${MCAST_PORT:-5000}"
        log_info "Concurrency:      ${PARALLEL_JOBS} parallel workers"
        log_info "=================================================================="

        # Pre-process image/audio inputs if provided
        local img_concat=""
        if [[ -n "${IMAGE_DIR}" ]]; then
            img_concat="$(collect_images "${IMAGE_DIR}" "${res_w}" "${res_h}")"
        fi

        local aud_input_args=()
        if (( NO_AUDIO == 0 )) && [[ -n "${AUDIO_INPUT}" ]]; then
            local audio_spec
            audio_spec="$(collect_audio "${AUDIO_INPUT}")"
            case "${audio_spec%%:*}" in
                file)
                    aud_input_args+=(-stream_loop -1 -i "${audio_spec#file:}")
                    ;;
                concat)
                    aud_input_args+=(-stream_loop -1 -f concat -safe 0 -i "${audio_spec#concat:}")
                    ;;
            esac
        fi

        local pids=()
        local active_channels=()
        local total_to_run=$(( end_ch - start_ch + 1 ))
        local completed=0
        local start_time
        start_time="$(date +%s)"

        for (( ch=start_ch; ch<=end_ch; ch++ )); do
            local ch_out_file="${MEDIA_DIR}/${CHANNEL_PREFIX}${ch}.ts"
            if (( CHANNEL_ID > 0 && CHANNELS_COUNT == 0 )) && [[ -n "${OUT_FILE:-}" && "${OUT_FILE}" != "${MEDIA_DIR}/${MEDIA_FILE}" ]]; then
                ch_out_file="${OUT_FILE}"
            fi

            render_channel_video "${ch}" "${end_ch}" "${ch_out_file}" "${res_w}" "${res_h}" "${buf_size}" "${gop}" "${img_concat}" "${aud_input_args[@]}" &
            pids+=($!)
            active_channels+=("${ch}")

            if (( ${#pids[@]} >= PARALLEL_JOBS )); then
                wait "${pids[0]}"
                local finished_ch="${active_channels[0]}"
                pids=("${pids[@]:1}")
                active_channels=("${active_channels[@]:1}")
                completed=$(( completed + 1 ))
                printf '\e[1;32m[DONE %2d/%2d]\e[0m Rendered Channel %2d -> %s\n' \
                    "${completed}" "${total_to_run}" "${finished_ch}" "${CHANNEL_PREFIX}${finished_ch}.ts"
            fi
        done

        for i in "${!pids[@]}"; do
            wait "${pids[i]}"
            local finished_ch="${active_channels[i]}"
            completed=$(( completed + 1 ))
            printf '\e[1;32m[DONE %2d/%2d]\e[0m Rendered Channel %2d -> %s\n' \
                "${completed}" "${total_to_run}" "${finished_ch}" "${CHANNEL_PREFIX}${finished_ch}.ts"
        done

        local end_time
        end_time="$(date +%s)"
        local elapsed=$(( end_time - start_time ))

        # Also create zero-padded symlinks (e.g. channel_01.ts -> channel_1.ts)
        local pad_fmt="%02d"
        if (( end_ch >= 100 )); then pad_fmt="%03d"; fi
        for (( ch=start_ch; ch<=end_ch; ch++ )); do
            local padded
            printf -v padded "${pad_fmt}" "${ch}"
            if [[ "${padded}" != "${ch}" ]]; then
                ln -sf "${CHANNEL_PREFIX}${ch}.ts" "${MEDIA_DIR}/${CHANNEL_PREFIX}${padded}.ts" 2>/dev/null || true
            fi
        done

        log_info "Successfully generated ${total_to_run} channel video(s) in ${elapsed}s!"
        log_info "Files saved in: ${MEDIA_DIR}/${CHANNEL_PREFIX}{${start_ch}..${end_ch}}.ts"
        return 0
    fi

    log_info "=================================================================="
    log_info "            IPTV MULTICAST MEDIA ASSET GENERATION"
    log_info "=================================================================="
    log_info "Output File:   ${OUT_FILE}"
    log_info "Duration:      ${DURATION} seconds"
    log_info "Resolution:    ${RESOLUTION} (${res_w}x${res_h})"
    log_info "Framerate:     ${FPS} fps (GOP=${gop})"
    log_info "Bitrate:       ${BITRATE} (buffer: ${buf_size}, preset: ${PRESET})"
    if [[ -n "${IMAGE_DIR}" ]]; then
        log_info "Video Input:   Images folder '${IMAGE_DIR}' (${IMAGE_DURATION}s/slide)"
    else
        log_info "Video Input:   Synthetic pattern '${PATTERN}'"
    fi
    if (( NO_AUDIO == 1 )); then
        log_info "Audio Input:   Disabled (-an)"
    elif [[ -n "${AUDIO_INPUT}" ]]; then
        log_info "Audio Input:   '${AUDIO_INPUT}' (${ACODEC}, ${ABITRATE})"
    else
        log_info "Audio Input:   Synthetic sine wave (${SINE_FREQ} Hz, ${ACODEC}, ${ABITRATE})"
    fi
    log_info "=================================================================="

    local ffmpeg_args=(-hide_banner -y)
    local output_opts=()

    # 1. Configure Video Input
    if [[ -n "${IMAGE_DIR}" ]]; then
        local img_concat
        img_concat="$(collect_images "${IMAGE_DIR}" "${res_w}" "${res_h}")"
        ffmpeg_args+=(-stream_loop -1 -f concat -safe 0 -i "${img_concat}")
        output_opts+=(
            -vf "format=yuv420p"
            -r "${FPS}"
        )
    else
        ffmpeg_args+=(-f lavfi -i "${PATTERN}=size=${RESOLUTION}:rate=${FPS}")
    fi

    # 2. Configure Audio Input
    if (( NO_AUDIO == 1 )); then
        output_opts+=(-an)
    elif [[ -n "${AUDIO_INPUT}" ]]; then
        local audio_spec
        audio_spec="$(collect_audio "${AUDIO_INPUT}")"
        case "${audio_spec%%:*}" in
            file)
                local aud_file="${audio_spec#file:}"
                ffmpeg_args+=(-stream_loop -1 -i "${aud_file}")
                output_opts+=(-c:a "${ACODEC}" -b:a "${ABITRATE}")
                ;;
            concat)
                local aud_concat="${audio_spec#concat:}"
                ffmpeg_args+=(-stream_loop -1 -f concat -safe 0 -i "${aud_concat}")
                output_opts+=(-c:a "${ACODEC}" -b:a "${ABITRATE}")
                ;;
            synthetic)
                ffmpeg_args+=(-f lavfi -i "sine=frequency=${SINE_FREQ}:sample_rate=48000")
                output_opts+=(-c:a "${ACODEC}" -b:a "${ABITRATE}")
                ;;
        esac
    else
        ffmpeg_args+=(-f lavfi -i "sine=frequency=${SINE_FREQ}:sample_rate=48000")
        output_opts+=(-c:a "${ACODEC}" -b:a "${ABITRATE}")
    fi

    # 3. Configure Encoding & Output
    output_opts+=(
        -t "${DURATION}"
        -c:v "${VCODEC}"
        -preset "${PRESET}"
        -b:v "${BITRATE}"
        -maxrate "${BITRATE}"
        -bufsize "${buf_size}"
        -g "${gop}"
        -f "${MPEGTS_CONTAINER}"
        "${OUT_FILE}"
    )

    ffmpeg_args+=("${output_opts[@]}")

    log_info "Encoding media asset with FFmpeg..."
    ffmpeg "${ffmpeg_args[@]}"

    if [[ ! -s "${OUT_FILE}" ]]; then
        die "Failed to generate media asset: ${OUT_FILE}"
    fi

    local fsize
    fsize="$(stat -c %s "${OUT_FILE}" 2>/dev/null || echo 0)"
    local fsize_mb
    fsize_mb="$(awk "BEGIN {printf \"%.2f\", ${fsize}/1048576}")"

    log_info "Media asset generated successfully!"
    log_info "Path: ${OUT_FILE}"
    log_info "Size: ${fsize_mb} MB (${fsize} bytes)"

    # Optional inspection with ffprobe
    if command -v ffprobe >/dev/null 2>&1; then
        log_info "Stream details:"
        ffprobe -hide_banner -select_streams v:0 -show_entries stream=codec_name,width,height,r_frame_rate -of csv=p=0 "${OUT_FILE}" 2>/dev/null | awk '{print "  Video: " $0}' || true
        ffprobe -hide_banner -select_streams a:0 -show_entries stream=codec_name,bit_rate,sample_rate -of csv=p=0 "${OUT_FILE}" 2>/dev/null | awk '{print "  Audio: " $0}' || true
    fi
}

main "$@"
