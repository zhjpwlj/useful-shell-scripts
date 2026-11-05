#!/bin/bash

# --- CONFIGURATION ---
TARGET_DIR="."           # Directory to scan (supports subdirectories)
OUTPUT_DIR="./fixed"     # Base directory to save fixed files
REPLACE_ORIGINAL=false   # Set to true to overwrite original files (Forced to false if extension changes)
LOG_FILE="/tmp/video_repair_$(date +%s).log"  # [Fix 7] Log file outside TARGET_DIR to prevent recursive self-scanning

# Deep scan duration in seconds. Set to 0 for a full exhaustive scan.
SCAN_SECONDS=${SCAN_SECONDS:-30}

# Initialize counters
COUNT_TOTAL=0
COUNT_SKIPPED=0
COUNT_CONVERTED=0
COUNT_REMUXED=0
COUNT_ENCODED=0
COUNT_RESCUED=0
COUNT_FAILED=0

# --- PRE-FLIGHT CHECKS & ENVIRONMENT VALIDATION ---
# [Minor] Check for required binaries upfront
for cmd in ffmpeg ffprobe awk df sort head; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "❌ Error: Required command '$cmd' is missing. Please install it first." >&2
        exit 1
    fi
done

# [Fix 6] Check FFmpeg version and log it
FFMPEG_VER=$(ffmpeg -version | head -n1)
echo "=== System Check: $FFMPEG_VER ==="

# [Fix 3] Signal Handling: Cleanup partial output and exit gracefully on Ctrl+C / SIGTERM / SIGHUP
CURRENT_PARTIAL_FILE=""
cleanup_on_interrupt() {
    echo -e "\n\n⚠️  Script interrupted by user or system signal!"
    if [ -n "$CURRENT_PARTIAL_FILE" ] && [ -f "$CURRENT_PARTIAL_FILE" ]; then
        echo "🧹 Cleaning up incomplete output file: $CURRENT_PARTIAL_FILE"
        rm -f "$CURRENT_PARTIAL_FILE"
    fi
    echo "📊 Partial stats: evaluated=$COUNT_TOTAL skipped=$COUNT_SKIPPED converted=$COUNT_CONVERTED remuxed=$COUNT_REMUXED encoded=$COUNT_ENCODED rescued=$COUNT_RESCUED failed=$COUNT_FAILED"
    echo "📜 Final partial log saved to: $LOG_FILE"
    exit 130
}
trap cleanup_on_interrupt INT TERM HUP

# [Fix 4] Disk Space Check (Require at least 1GB / 1048576 KB free to start)
MIN_SPACE_KB=1048576
avail_space=$(df -P "$TARGET_DIR" | awk 'NR==2 {print $4}')
if ! [[ "$avail_space" =~ ^[0-9]+$ ]]; then
    echo "❌ Error: Unable to determine free disk space for '$TARGET_DIR'." >&2
    exit 1
fi
if [ "$avail_space" -lt "$MIN_SPACE_KB" ]; then
    echo "❌ Error: Insufficient disk space on target partition (${avail_space}KB available). At least 1GB is required." >&2
    exit 1
fi

# Resolve absolute path for OUTPUT_DIR to prevent self-processing
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"

# Initialize log file
echo "=== Video Repair Log - $(date) ===" > "$LOG_FILE"
echo "System Check: $FFMPEG_VER" >> "$LOG_FILE"
echo "Target Scan Directory: $(cd "$TARGET_DIR" && pwd)" >> "$LOG_FILE"
echo "Available Space: ${avail_space}KB" >> "$LOG_FILE"

# --- ARGUMENT HANDLING (EXTENSION CONVERSION) ---
TARGET_EXT=""
if [ -n "$1" ]; then
    TARGET_EXT="${1#.}"
    TARGET_EXT=$(echo "$TARGET_EXT" | tr '[:upper:]' '[:lower:]')
    echo "🎯 Extension Conversion Enabled: Target format is .$TARGET_EXT"
    REPLACE_ORIGINAL=false
fi

if ! [[ "$SCAN_SECONDS" =~ ^[0-9]+$ ]]; then
    echo "❌ Error: SCAN_SECONDS must be a non-negative integer (got '$SCAN_SECONDS')." >&2
    exit 1
fi

echo "=== Starting Enterprise-Grade Video Corruption Check, Repair & Conversion ==="
echo "=== Maintaining original subdirectory structures under $OUTPUT_DIR ==="
echo "=== Scan Depth Configuration: SCAN_SECONDS=$SCAN_SECONDS ==="
echo "========================================================================"

# --- PROCESS SUBSTITUTION TO PRESERVE COUNTERS IN MAIN SHELL ---
while IFS= read -r -d '' file; do

    # Resolve absolute path of the current file to bulletproof the skip check
    abs_file="$(cd "$(dirname "$file")" && pwd)/$(basename "$file")"
    if [[ "$abs_file" == "$OUTPUT_DIR"/* ]]; then
        continue
    fi

    filename=$(basename "$file")

    # Guard: Skip files with no extensions
    if [[ "$filename" != *.* ]]; then
        continue
    fi

    ((COUNT_TOTAL++))

    # [Fix 5] Progress Feedback: Print status every 10 files to keep the user informed
    if (( COUNT_TOTAL % 10 == 0 )); then
        echo "📊 Progress Update: Evaluated $COUNT_TOTAL files so far..."
    fi

    rel_path="${file#./}"
    rel_dir=$(dirname "$rel_path")
    src_ext=$(echo "${filename##*.}" | tr '[:upper:]' '[:lower:]')

    # Determine the output filename and final destination extension
    if [ -n "$TARGET_EXT" ]; then
        out_filename="${filename%.*}.$TARGET_EXT"
        dest_ext="$TARGET_EXT"
    else
        case "$src_ext" in
            rmvb|rm|asf|divx|vob|flv|wmv) out_filename="${filename%.*}.mp4"; dest_ext="mp4" ;;
            *)                            out_filename="$filename";           dest_ext="$src_ext" ;;
        esac
    fi

    echo "------------------------------------------------------------------------"
    echo "🔍 Checking [$COUNT_TOTAL]: $file"

    # --- CODEC & SUBTITLE MAPPING BASED ON TARGET CONTAINER ---
    case "$dest_ext" in
        webm|ogv)     vcodec="libvpx-vp9"; acodec="libopus"; scodec="copy" ;;
        mp4|m4v|mov)  vcodec="libx264";    acodec="aac";     scodec="mov_text" ;;
        *)            vcodec="libx264";    acodec="aac";     scodec="copy" ;;
    esac

    # Define target fixed directory
    if [ "$rel_dir" = "." ]; then current_out_dir="$OUTPUT_DIR"; else current_out_dir="$OUTPUT_DIR/$rel_dir"; fi
    out_file="$current_out_dir/$out_filename"

    # Register current file path for the trap signal handler
    CURRENT_PARTIAL_FILE="$out_file"

    # --- INTEGRITY CHECK ---
    IS_CORRUPT=false

    # Step A: Quick header check
    duration=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null)

    # [Fix 1 - CORRECTED] bc-free numeric check via awk.
    # Handles empty/N/A strings (coerce to 0 -> corrupt) and negative decimals correctly.
    # NOTE: The previous 'sort -g | head -n1 == 0' version was inverted: it flagged
    # healthy files (duration > 0) as corrupt, and negative decimals crashed the (( )) test.
    if [ -z "$duration" ] || [ "$duration" = "N/A" ]; then
        IS_CORRUPT=true
        echo "   [!] Container header is broken (Missing duration)."
    elif awk -v d="$duration" 'BEGIN { exit !(d + 0 <= 0) }'; then
        IS_CORRUPT=true
        echo "   [!] Container header reports zero or negative duration ($duration)."
    else
        # Step B: Deep stream decode check
        scan_flag=""
        if [ "$SCAN_SECONDS" -gt 0 ]; then scan_flag="-t $SCAN_SECONDS"; fi

        tmp_err=$(ffmpeg -v error -err_detect explode $scan_flag -i "$file" -f null - 2>&1)
        if [ -n "$tmp_err" ]; then
            IS_CORRUPT=true
            echo "   [!] Stream corruption detected by deep scan."
            echo -e "--- Corruption in $file ---\n$tmp_err\n" >> "$LOG_FILE"
        fi
    fi

    # --- DECISION LOGIC: TO CONVERT OR TO SKIP ---
    if [ "$IS_CORRUPT" = false ]; then
        if [ -n "$TARGET_EXT" ] && [ "$src_ext" != "$TARGET_EXT" ]; then
            echo "   [+] File is healthy. Converting container to .$TARGET_EXT..."
            mkdir -p "$current_out_dir"

            if ffmpeg -y -i "$file" -map 0 -c copy "$out_file" >> "$LOG_FILE" 2>&1; then
                echo "   ✨ Successfully converted -> $out_file"
                ((COUNT_CONVERTED++))
                CURRENT_PARTIAL_FILE=""
                continue
            else
                echo "   ⚠️  Remux conversion failed (likely subtitle incompatibility). Re-encoding without subtitles..."
                if ffmpeg -y -i "$file" -map 0:v:0 -map 0:a? -c:v "$vcodec" -c:a "$acodec" -sn "$out_file" >> "$LOG_FILE" 2>&1; then
                    echo "   ✨ Successfully converted (via re-encode) -> $out_file"
                    ((COUNT_CONVERTED++))
                    CURRENT_PARTIAL_FILE=""
                    continue
                fi
            fi
        fi
        echo "   ✅ File is healthy and format matches. Skipping."
        ((COUNT_SKIPPED++))
        CURRENT_PARTIAL_FILE=""
        continue
    fi

    # --- REPAIR ESCALATION PATHWAY ---
    mkdir -p "$current_out_dir"

    # 1. REMUX STRATEGY (Fastest, zero quality loss)
    echo "   [1/3] Attempting fast remuxing..."
    if ffmpeg -y -err_detect ignore_err -i "$file" -map 0 -c copy "$out_file" >> "$LOG_FILE" 2>&1; then
        if ffprobe -v error -show_entries format=duration "$out_file" > /dev/null 2>&1; then
            echo "   ✨ Success! Repaired via container remuxing -> $out_file"
            ((COUNT_REMUXED++))
            if [ "$REPLACE_ORIGINAL" = true ] && [ "$src_ext" = "$dest_ext" ]; then mv "$out_file" "$file"; fi
            CURRENT_PARTIAL_FILE=""
            continue
        fi
    fi

    # 2. FULL RE-ENCODE STRATEGY (Deep structure rebuilding with dynamic mapping)
    echo "   [2/3] Remux failed. Attempting forced full re-encoding (all tracks)..."
    if ffmpeg -y -err_detect ignore_err -i "$file" -map 0 -c:v "$vcodec" -c:a "$acodec" -c:s "$scodec" "$out_file" >> "$LOG_FILE" 2>&1; then
        if ffprobe -v error -show_entries format=duration "$out_file" > /dev/null 2>&1; then
            echo "   ✨ Success! Repaired via dynamic re-encoding -> $out_file"
            ((COUNT_ENCODED++))
            if [ "$REPLACE_ORIGINAL" = true ] && [ "$src_ext" = "$dest_ext" ]; then mv "$out_file" "$file"; fi
            CURRENT_PARTIAL_FILE=""
            continue
        fi
    fi

    # 3. EMERGENCY RESCUE STRATEGY (Strip subtitles, isolate primary core video & preserve ALL available audio)
    # [Fix 2] Multi-audio stream preservation fallback using -map 0:a instead of single track dropping
    echo "   ⚠️  Warning: Full track re-encode failed. Dropping to emergency stream salvage (dropping subtitles, keeping all audio paths)..."
    if ffmpeg -y -err_detect ignore_err -i "$file" -map 0:v:0 -map 0:a? -c:v "$vcodec" -c:a "$acodec" -sn "$out_file" >> "$LOG_FILE" 2>&1; then
        if ffprobe -v error -show_entries format=duration "$out_file" > /dev/null 2>&1; then
            echo "   ✨ Success! Salvaged core video and all available audio streams -> $out_file"
            ((COUNT_RESCUED++))
            if [ "$REPLACE_ORIGINAL" = true ] && [ "$src_ext" = "$dest_ext" ]; then mv "$out_file" "$file"; fi
            CURRENT_PARTIAL_FILE=""
            continue
        fi
    fi

    echo "   ❌ Severe corruption. File could not be salvaged."
    ((COUNT_FAILED++))
    rm -f "$out_file"
    CURRENT_PARTIAL_FILE=""

done < <(find "$TARGET_DIR" -type f \( \
    -iname '*.mp4'  -o -iname '*.mkv'  -o -iname '*.avi'  -o \
    -iname '*.mov'  -o -iname '*.flv'  -o -iname '*.wmv'  -o \
    -iname '*.webm' -o -iname '*.m4v'  -o -iname '*.ts'   -o \
    -iname '*.m2ts' -o -iname '*.3gp'  -o -iname '*.3g2'  -o \
    -iname '*.ogv'  -o -iname '*.ogg'  -o -iname '*.vob'  -o \
    -iname '*.mts'  -o -iname '*.f4v'  -o -iname '*.rmvb' -o \
    -iname '*.rm'   -o -iname '*.asf'  -o -iname '*.divx' \
\) -print0)

# --- FINAL SUMMARY BANNER ---
echo "========================================================================"
echo "===                       REPAIR TASK SUMMARY                        ==="
echo "========================================================================"
echo " 📂 Total files scanned:      $COUNT_TOTAL"
echo " 🟢 Healthy files skipped:    $COUNT_SKIPPED"
echo " 🔵 Healthy files converted:  $COUNT_CONVERTED"
echo " ⚡ Repaired via Remuxing:    $COUNT_REMUXED"
echo " 🌀 Repaired via Encoding:    $COUNT_ENCODED"
echo " ⚠️  Salvaged via Rescue:     $COUNT_RESCUED"
echo " ❌ Failed to salvage:        $COUNT_FAILED"
echo "========================================================================"
echo " For detailed error descriptions, please check: $LOG_FILE"
