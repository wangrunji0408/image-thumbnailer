#!/bin/bash
# Test all RAW files in a directory against our CLI tool
# Usage: ./test_all_raws.sh <directory>

DIR="${1:-.}"
CLI="$(pwd)/.build/release/ImageThumbnailerCLI"

# Build first
swift build -c release 2>&1 | tail -1

RESULTS_FILE=$(mktemp)
MAX_JOBS=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)

process_file() {
    local f="$1"
    local DIR="$2"
    local CLI="$3"

    name=$(basename "$f")
    ext="${name##*.}"
    ext_lower=$(echo "$ext" | tr '[:upper:]' '[:lower:]')
    relpath="${f#$DIR/}"

    # Get exiftool baseline
    et_w=$(exiftool -s -s -s -ImageWidth "$f" 2>/dev/null)
    et_h=$(exiftool -s -s -s -ImageHeight "$f" 2>/dev/null)

    # Map extension to CLI reader
    case "$ext_lower" in
        arw) ;;
        nef|nrw) ext_lower="nef" ;;
        dng) ;;
        pef) ;;
        rw2) ;;
        orf) ;;
        cr2) ;;
        cr3) ;;
        *) echo "NOSUP    ${ext_lower}  ${relpath}  exiftool:${et_w}x${et_h}"; return ;;
    esac

    # Create temp files with unique names (PID-based)
    tmpfile="/tmp/_test_raw_$$.${ext_lower}"
    thumb_out="/tmp/_thumb_test_$$.jpg"
    abs_path="$(cd "$(dirname "$f")" && pwd)/$(basename "$f")"
    ln -sf "$abs_path" "$tmpfile" 2>/dev/null
    result=$("$CLI" "$tmpfile" -o "$thumb_out" 2>&1)
    exit_code=$?

    # Check if output thumbnail is a valid image
    valid_image=""
    if [ -f "$thumb_out" ]; then
        if file "$thumb_out" | grep -qiE "JPEG|PNG|TIFF|HEIF|HEIC|ISO Media"; then
            valid_image="valid"
        else
            valid_image="INVALID"
        fi
    fi

    rm -f "$tmpfile"

    if echo "$result" | grep -q "found [0-9]"; then
        thumb_count=$(echo "$result" | grep "found" | sed 's/found \([0-9]*\).*/\1/')
        our_size=$(echo "$result" | grep "size:" | head -1 | sed 's/.*size: //')
        if [ "$thumb_count" -gt 0 ] && [ "$valid_image" = "valid" ]; then
            echo "OK       ${ext_lower}  ${relpath}  exiftool:${et_w}x${et_h}  ours:${our_size}  thumbs:${thumb_count}"
            echo "OK"
        elif [ "$thumb_count" -gt 0 ] && [ "$valid_image" = "INVALID" ]; then
            echo "FAIL     ${ext_lower}  ${relpath}  exiftool:${et_w}x${et_h}  ours:${our_size}  thumbs:${thumb_count}  (invalid image)"
            echo "FAIL"
        else
            echo "NO THUMB ${ext_lower}  ${relpath}  exiftool:${et_w}x${et_h}  ours:${our_size}  (no thumbnails)"
            echo "NO THUMB"
        fi
    elif echo "$result" | grep -q "no thumbnail"; then
        our_size=$(echo "$result" | grep "size:" | head -1 | sed 's/.*size: //')
        echo "NO THUMB ${ext_lower}  ${relpath}  exiftool:${et_w}x${et_h}  ours:${our_size}  (no thumbnails)"
        echo "NO THUMB"
    else
        error_msg=$(echo "$result" | grep -i "error" | head -1 | sed 's/.*Error: //')
        echo "FAIL     ${ext_lower}  ${relpath}  exiftool:${et_w}x${et_h}  ${error_msg}"
        echo "FAIL"
    fi

    rm -f "$thumb_out"
}

export -f process_file

# Find all supported RAW files and process in parallel
find "$DIR" -type f \( \
    -iname "*.arw" -o -iname "*.nef" -o -iname "*.nrw" \
    -o -iname "*.dng" -o -iname "*.pef" -o -iname "*.rw2" \
    -o -iname "*.orf" -o -iname "*.cr2" -o -iname "*.cr3" \
    \) 2>/dev/null | sort | xargs -P "$MAX_JOBS" -I {} bash -c 'process_file "$@"' _ {} "$DIR" "$CLI" \
    | tee >(grep -E "^(OK|FAIL|NO THUMB)$" > "$RESULTS_FILE") \
    | grep -v -E "^(OK|FAIL|NO THUMB)$"

wait

TOTAL=$(wc -l < "$RESULTS_FILE" | tr -d ' ')
OK=$(grep -c "^OK$" "$RESULTS_FILE" || true)
NO_THUMB=$(grep -c "^NO THUMB$" "$RESULTS_FILE" || true)
FAIL=$(grep -c "^FAIL$" "$RESULTS_FILE" || true)
rm -f "$RESULTS_FILE"

echo ""
echo "=== Summary ==="
echo "Total: $TOTAL  OK: $OK  No Thumb: $NO_THUMB  Fail: $FAIL"
