#!/bin/bash

# --- CONFIGURATION ---
TARGET_DIR="."           # Directory to scan (supports subdirectories)
OUTPUT_DIR="./fixed"     # Base directory to save fixed files
REPLACE_ORIGINAL=false    # Set to true to overwrite original files (Disabled if extension conversion is requested)

# --- ARGUMENT HANDLING (EXTENSION CONVERSION) ---
# Check if a target extension argument is provided (e.g., ./fix_videos.sh mp4)
TARGET_EXT=""
if [ -n "$1" ]; then
    # Remove leading dot if user typed it (e.g., ".mp4" -> "mp4")
    TARGET_EXT="${1#.}"
    # Convert to lowercase
    TARGET_EXT=$(echo "$TARGET_EXT" | tr '[:upper:]' '[:lower:]')
    echo "🎯 Extension Conversion Enabled: All fixed videos will be converted to .$TARGET_EXT"
    
    # Force REPLACE_ORIGINAL to false because changing extension means changing file name
    REPLACE_ORIGINAL=false
fi

# Create base output directory if it doesn't exist
mkdir -p "$OUTPUT_DIR"

echo "=== Starting Deep Video Corruption Check, Repair & Conversion ==="
echo "=== Maintaining original subdirectory structures under $OUTPUT_DIR ==="
echo "=== Keeping ALL audio tracks, subtitles, and metadata ==="

# Scan for ALL common and rare video formats recursively
find "$TARGET_DIR" -type f \( \
    -iname "*.mp4" -o -iname "*.mkv" -o -iname "*.avi" -o \
    -iname "*.mov" -o -iname "*.flv" -o -iname "*.wmv" -o \
    -iname "*.webm" -o -iname "*.m4v" -o -iname "*.ts" -o \
    -iname "*.m2ts" -o -iname "*.3gp" -o -iname "*.3g2" -o \
    -iname "*.ogv" -o -iname "*.ogg" -o -iname "*.vob" -o \
    -iname "*.mts" -o -iname "*.f4v" -o -iname "*.rmvb" -o \
    -iname "*.rm" -o -iname "*.asf" -o -iname "*.divx" \
\) | while read -r file; do
    
    # Skip files inside the fixed directory and the script itself
    if [[ "$file" == "$OUTPUT_DIR"* ]]; then
        continue
    fi

    # Get the relative path of the file to replicate directory structure
    rel_path="${file#./}"
    rel_dir=$(dirname "$rel_path")
    filename=$(basename "$file")
    
    # Determine the output filename and format
    if [ -n "$TARGET_EXT" ]; then
        # Replace original extension with the requested target extension
        out_filename="${filename%.*}.$TARGET_EXT"
    else
        out_filename="$filename"
    fi
    
    echo "----------------------------------------"
    echo "Checking: $file"

    # 1. Quick integrity check using ffprobe
    if ffprobe -v error -show_entries format=duration "$file" > /dev/null 2>&1; then
        echo "✅ File appears to be valid. Skipping."
        continue
    fi

    echo "⚠️  Corruption detected! Attempting to fix..."
    
    # Define target fixed directory and create it if it doesn't exist
    if [ "$rel_dir" = "." ]; then
        current_out_dir="$OUTPUT_DIR"
    else
        current_out_dir="$OUTPUT_DIR/$rel_dir"
    fi
    mkdir -p "$current_out_dir"
    
    out_file="$current_out_dir/$out_filename"

    # 2. Try fast remuxing (rebuilding container metadata without losing quality)
    # Note: Remuxing between different containers (like avi to mp4) may fail depending on codecs.
    if ffmpeg -y -err_detect ignore_err -i "$file" -map 0 -c copy "$out_file" > /dev/null 2>&1; then
        
        # Verify if the remuxed file is now valid
        if ffprobe -v error -show_entries format=duration "$out_file" > /dev/null 2>&1; then
            echo "✨ Success! File repaired via remuxing -> $out_file"
            
            if [ "$REPLACE_ORIGINAL" = true ]; then
                mv "$out_file" "$file"
                echo "♻️  Original file replaced with the fixed version."
            fi
            continue
        fi
    fi

    # 3. If remuxing fails, try full re-encoding as a fallback
    echo "🔄 Fast repair failed. Attempting forced re-encoding for ALL tracks (this takes longer)..."
    if ffmpeg -y -err_detect ignore_err -i "$file" -map 0 -c:v libx264 -c:a aac -c:s copy "$out_file" > /dev/null 2>&1; then
        if ffprobe -v error -show_entries format=duration "$out_file" > /dev/null 2>&1; then
            echo "✨ Success! File repaired via re-encoding -> $out_file"
            if [ "$REPLACE_ORIGINAL" = true ]; then
                mv "$out_file" "$file"
                echo "♻️  Original file replaced with the fixed version."
            fi
        else
            echo "❌ Re-encoded file still has errors. Giving up."
            rm -f "$out_file"
        fi
    else
        # 4. Emergency Rescue (Main stream only) if all-track encoding fails
        # (Very useful when converting containers like MKV to MP4, as MP4 doesn't support certain MKV subtitle formats)
        echo "⚠️  All-track encoding failed. Trying emergency rescue (main video/audio only)..."
        if ffmpeg -y -err_detect ignore_err -i "$file" -c:v libx264 -c:a aac "$out_file" > /dev/null 2>&1; then
            if ffprobe -v error -show_entries format=duration "$out_file" > /dev/null 2>&1; then
                echo "✨ Success! Rescued main video/audio stream -> $out_file"
                if [ "$REPLACE_ORIGINAL" = true ]; then
                    mv "$out_file" "$file"
                    echo "♻️  Original file replaced with the fixed version."
                fi
                continue
            fi
        fi
        echo "❌ Severe corruption. FFmpeg cannot process this file (data might be missing)."
        rm -f "$out_file"
    fi

done

echo "========================================"
echo "All tasks completed."
