#!/usr/bin/env bash
set -euo pipefail

URL="${1:?Usage: $0 <YouTube URL> <highest|high|medium|low|lower|lowest>}"
QUALITY="${2:-highest}"

COOKIES="${COOKIES:-cookies.txt}"
OUTPUT_ROOT="${OUTPUT_ROOT:-.}"
OUTPUT_DIR="${OUTPUT_ROOT}/videos"
TEMP_DIR="${TEMP_DIR:-${OUTPUT_ROOT}/.tmp_videos}"

SLEEP_MIN="${SLEEP_MIN:-3}"
SLEEP_MAX="${SLEEP_MAX:-12}"
SUB_LANGS="${SUB_LANGS:-ja.*,en.*}"
AUTO_SUBS="${AUTO_SUBS:-0}"
VERBOSE="${VERBOSE:-0}"

for cmd in yt-dlp ffmpeg ffprobe node; do
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "❌ Missing dependency: $cmd" >&2
        exit 1
    }
done

NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"

if (( NODE_MAJOR < 20 )); then
    echo "⚠️ Node $NODE_MAJOR detected; Node 20+ is recommended." >&2
fi

ARGS=()

if [[ -f "$COOKIES" ]]; then
    ARGS+=(--cookies "$COOKIES")
else
    ARGS+=(--cookies-from-browser firefox)
fi

[[ "$VERBOSE" == "1" ]] && ARGS+=(-v)

if [[ "$SLEEP_MAX" != "0" ]]; then
    ARGS+=(
        --sleep-requests 0.1
        --sleep-interval "$SLEEP_MIN"
        --max-sleep-interval "$SLEEP_MAX"
        --sleep-subtitles "$SLEEP_MIN"
    )
fi

# Quality caps apply to the SHORTER side of the video (min(width, height)),
# so 240 means 240p for normal videos and 240px wide for Shorts.
FORMAT='bv*[vcodec^=avc1]+ba[acodec^=mp4a]/bv*+ba/b'
SORT_ARGS=()

case "$QUALITY" in
    highest) ;;                                # no cap
    high)    SORT_ARGS=(-S "res:1080") ;;
    medium)  SORT_ARGS=(-S "res:720") ;;
    low)     SORT_ARGS=(-S "res:480") ;;
    lower)   SORT_ARGS=(-S "res:360") ;;
    lowest)  SORT_ARGS=(-S "res:240") ;;
    *)
        echo "❌ Invalid quality: $QUALITY" >&2
        exit 2
        ;;
esac

SUB_ARGS=(
    --embed-subs
    --sub-langs "$SUB_LANGS"
    --sub-format "vtt/best"
    --convert-subs srt
)

[[ "$AUTO_SUBS" == "1" ]] && SUB_ARGS+=(--write-auto-subs)

mkdir -p "$OUTPUT_DIR" "$TEMP_DIR"

META="$(
    yt-dlp \
        "${ARGS[@]}" \
        --flat-playlist \
        --playlist-items 1 \
        --print '%(channel)s	%(playlist_title)s' \
        "$URL"
)"

CHANNEL_NAME="${META%%$'\t'*}"
PLAYLIST_TITLE="${META#*$'\t'}"

CHANNEL_NAME="${CHANNEL_NAME:-channel}"
PLAYLIST_TITLE="${PLAYLIST_TITLE:-playlist}"

SAFE_CHANNEL_NAME="$CHANNEL_NAME"
SAFE_CHANNEL_NAME="${SAFE_CHANNEL_NAME//\//_}"
SAFE_CHANNEL_NAME="${SAFE_CHANNEL_NAME//\\/_}"
SAFE_CHANNEL_NAME="${SAFE_CHANNEL_NAME//:/_}"
SAFE_CHANNEL_NAME="${SAFE_CHANNEL_NAME//\?/_}"
SAFE_CHANNEL_NAME="${SAFE_CHANNEL_NAME//\*/_}"
SAFE_CHANNEL_NAME="${SAFE_CHANNEL_NAME//\"/_}"
SAFE_CHANNEL_NAME="${SAFE_CHANNEL_NAME//</_}"
SAFE_CHANNEL_NAME="${SAFE_CHANNEL_NAME//>/_}"
SAFE_CHANNEL_NAME="${SAFE_CHANNEL_NAME//|/_}"

SAFE_PLAYLIST_TITLE="$PLAYLIST_TITLE"
SAFE_PLAYLIST_TITLE="${SAFE_PLAYLIST_TITLE//\//_}"
SAFE_PLAYLIST_TITLE="${SAFE_PLAYLIST_TITLE//\\/_}"
SAFE_PLAYLIST_TITLE="${SAFE_PLAYLIST_TITLE//:/_}"
SAFE_PLAYLIST_TITLE="${SAFE_PLAYLIST_TITLE//\?/_}"
SAFE_PLAYLIST_TITLE="${SAFE_PLAYLIST_TITLE//\*/_}"
SAFE_PLAYLIST_TITLE="${SAFE_PLAYLIST_TITLE//\"/_}"
SAFE_PLAYLIST_TITLE="${SAFE_PLAYLIST_TITLE//</_}"
SAFE_PLAYLIST_TITLE="${SAFE_PLAYLIST_TITLE//>/_}"
SAFE_PLAYLIST_TITLE="${SAFE_PLAYLIST_TITLE//|/_}"

CHANNEL_DIR="${OUTPUT_DIR}/${SAFE_CHANNEL_NAME}"
ARCHIVE="${CHANNEL_DIR}/archive-${SAFE_PLAYLIST_TITLE}.txt"

mkdir -p "$CHANNEL_DIR"
touch "$ARCHIVE"

cleanup() {
    find "$OUTPUT_DIR" -type f -name '*.jpg' -print0 |
        while IFS= read -r -d '' f; do
            [[ -f "${f%.jpg}.mp4" ]] && rm -f -- "$f"
        done

    rmdir "$TEMP_DIR" 2>/dev/null || true
}

trap cleanup EXIT

echo "➡️ $CHANNEL_NAME / $PLAYLIST_TITLE [$QUALITY]"
echo "📁 $OUTPUT_DIR"

yt-dlp \
    "${ARGS[@]}" \
    "${SUB_ARGS[@]}" \
    --progress \
    --progress-template 'download:[%(progress._percent_str)s] %(progress._downloaded_bytes_str)s / %(progress._total_bytes_str)s at %(progress._speed_str)s ETA %(progress._eta_str)s' \
    --download-archive "$ARCHIVE" \
    --no-js-runtimes \
    --js-runtimes node \
    --impersonate chrome \
    --no-wait-for-video \
    --playlist-reverse \
    --concurrent-fragments 8 \
    --retries 32 \
    --fragment-retries 64 \
    --socket-timeout 60 \
    --buffer-size 16M \
    --continue \
    --match-filters 'duration <= 3600 & title !*= "総集編"' \
    -f "$FORMAT" \
    "${SORT_ARGS[@]}" \
    --merge-output-format mp4 \
    --embed-metadata \
    --embed-thumbnail \
    --convert-thumbnails jpg \
    --extractor-args "youtube:player_client=default,web_embedded" \
    -P "home:${OUTPUT_DIR}" \
    -P "temp:${TEMP_DIR}" \
    -o "%(channel)s/%(playlist_title)s/[%(upload_date>%Y-%m-%d)s]#%(title)s.%(ext)s" \
    --proxy "http://zterzytb:fkv17mn9n3ht@198.23.243.226:6361/" \
    "$URL"

echo "✅ Done."
