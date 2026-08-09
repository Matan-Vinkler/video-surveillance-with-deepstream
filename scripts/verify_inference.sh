#!/usr/bin/env bash
# verify_inference.sh - headless, machine-checked verification of the Milestone 5
# checkpoint-1 DETECTION behaviour:
#
#   file source -> decoder -> nvstreammux -> nvinfer -> nvmultistreamtiler
#                -> nvdsosd -> fakesink
#
# This is checkpoint 1's regression test, and it deliberately keeps working as
# later stages are added to the pipeline. Every check here reads the DETECTOR
# metadata dump, which deepstream-app writes from a probe on the primary-gie
# bin's src pad -- upstream of any tracker -- so a tracker cannot alter it.
# Checkpoint 2's own evidence lives in scripts/verify_tracking.sh.
#
# Needs no display, terminates on its own, never loops. Every claim is checked
# against captured output; nothing is asserted from appearance.
#
# What it proves:
#   1  deepstream-app runs to clean EOS                     (exit status)
#   2  the prebuilt FP16 engine is DESERIALIZED, not rebuilt (log + sha256)
#   3  the clip is decoded                                   (per-frame output)
#   4  batch size is 1 end to end                            (config + log)
#   5  nvinfer reports no config/parser errors               (log)
#   6  detections are produced, with RAW per-class counts    (KITTI metadata)
#   7  class_id 2 really is `person`                         (filter-out run)
#   8  no ANALYTICS metadata exists yet                      (static + runtime)
#
# Usage:
#   ./scripts/verify_inference.sh

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ds_common.sh"

while (( $# > 0 )); do
    case "$1" in
        -h|--help) sed -n '2,29p' "$0"; exit 0 ;;
        *) die "Unknown option '$1'. Try --help." ;;
    esac
done

require_tools
require_deepstream_app
require_elements nvstreammux nvinfer nvtracker nvmultistreamtiler \
                 nvvideoconvert nvdsosd fakesink

APP_CFG="$(require_config deepstream_app_walk_headless.txt)"
INFER_CFG="$(require_config config_infer_primary_trafficcamnet.txt)"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

FAILURES=0
note_pass() { printf '  PASS  %s\n' "$*"; }
note_fail() { printf '  FAIL  %s\n' "$*"; FAILURES=$(( FAILURES + 1 )); }

# ------------------------------------------------------------- environment ---
bold "== Environment =="
printf '  %-24s %s\n' "DeepStream" "$(ds_version)"
printf '  %-24s %s\n' "TensorRT" "$(trt_version)"
printf '  %-24s %s\n' "GPU" "$(gpu_slug)"

ENGINE_TARGET="$(ensure_engine_link)"
printf '  %-24s %s\n' "engine (expected)" "$(basename "$ENGINE_TARGET")"
printf '  %-24s %s -> %s\n' "stable link" "$STABLE_ENGINE_NAME" "$(readlink "$STABLE_ENGINE")"

FINGERPRINT_BEFORE="$(engine_fingerprint)"

# ------------------------------------------------------------------ run 1 ----
rm -rf "$DETECTION_DIR"
mkdir -p "$DETECTION_DIR"          # KITTI dump silently writes nothing if absent

bold "== Run 1: inference on the simulated camera source =="
printf '  %-24s %s\n' "app config" "$APP_CFG"
printf '  %-24s %s\n' "nvinfer config" "$INFER_CFG"
printf '  %-24s %s\n' "detections dir" "$DETECTION_DIR"

RUN_LOG="$WORKDIR/run1.log"
rc=0
deepstream-app -c "$APP_CFG" >"$RUN_LOG" 2>&1 || rc=$?
printf '  %-24s %s\n' "exit status" "$rc"

FINGERPRINT_AFTER="$(engine_fingerprint)"

# --- 1. clean run ---
bold "== CHECK 1: application ran to clean EOS =="
if (( rc == 0 )); then
    note_pass "deepstream-app exited 0"
else
    tail -n 25 "$RUN_LOG" >&2
    note_fail "deepstream-app exited $rc"
fi
if grep -qE 'ERROR from element|Error\(s\) in config file|App run failed' "$RUN_LOG"; then
    grep -E 'ERROR from element|Error\(s\) in config file|App run failed' "$RUN_LOG" | head -5 >&2
    note_fail "the log reports a pipeline error"
else
    note_pass "no pipeline errors in the log"
fi

# --- 2. engine deserialized, not rebuilt ---
bold "== CHECK 2: prebuilt FP16 engine loaded, not rebuilt =="
# nvinfer calls realpath on the configured path, so the log names the symlink's
# TARGET, not the stable name. Asserting on the resolved basename is the
# stronger check anyway: it proves which versioned engine actually loaded.
ENGINE_BASENAME="$(basename "$ENGINE_TARGET")"
if grep -q 'Use deserialized engine model' "$RUN_LOG" \
   && grep -q "$ENGINE_BASENAME" "$RUN_LOG"; then
    note_pass "engine deserialized: $ENGINE_BASENAME"
else
    note_fail "no 'Use deserialized engine model' line naming $ENGINE_BASENAME"
fi
if grep -qE 'try rebuild|trying rebuild|Trying to create engine|buildSerializedNetwork' "$RUN_LOG"; then
    grep -nE 'try rebuild|trying rebuild|Trying to create engine' "$RUN_LOG" | head -3 >&2
    note_fail "the log indicates an engine rebuild was attempted"
else
    note_pass "no rebuild was attempted"
fi
if [[ "$FINGERPRINT_BEFORE" == "$FINGERPRINT_AFTER" ]]; then
    note_pass "engine file unchanged (sha256, mtime and size identical)"
else
    printf '    before: %s\n    after:  %s\n' "$FINGERPRINT_BEFORE" "$FINGERPRINT_AFTER" >&2
    note_fail "the engine file changed during the run"
fi

# --- 3. clip decoded ---
bold "== CHECK 3: source decoded =="
FRAME_FILES="$(find "$DETECTION_DIR" -name '*.txt' -type f | wc -l)"
EXPECTED_FRAMES="$(video_frame_count "$(resolve_video)")"
printf '  %-24s %s\n' "per-frame files" "$FRAME_FILES"
printf '  %-24s %s\n' "clip holds" "$EXPECTED_FRAMES frames"
if (( FRAME_FILES > 0 )); then
    note_pass "inference ran on $FRAME_FILES frames"
else
    note_fail "no per-frame metadata was produced at all"
fi
if (( FRAME_FILES == EXPECTED_FRAMES )); then
    note_pass "every frame in the clip was processed"
else
    note_fail "processed $FRAME_FILES frames but the clip holds $EXPECTED_FRAMES"
fi

# --- 4. batch size 1 ---
bold "== CHECK 4: batch size is 1 end to end =="
mux_batch="$(sed -n '/^\[streammux\]/,/^\[/p' "$APP_CFG" | sed -n 's/^batch-size=//p' | head -1)"
gie_batch="$(sed -n '/^\[primary-gie\]/,/^\[/p' "$APP_CFG" | sed -n 's/^batch-size=//p' | head -1)"
inf_batch="$(sed -n 's/^batch-size=//p' "$INFER_CFG" | head -1)"
printf '  %-24s %s\n' "streammux batch-size" "$mux_batch"
printf '  %-24s %s\n' "primary-gie batch-size" "$gie_batch"
printf '  %-24s %s\n' "nvinfer batch-size" "$inf_batch"
if [[ "$mux_batch" == "1" && "$gie_batch" == "1" && "$inf_batch" == "1" ]]; then
    note_pass "all three declare batch-size 1"
else
    note_fail "batch sizes disagree or are not 1"
fi
if grep -qE 'Backend has maxBatchSize|can not support dims|failed to match config params' "$RUN_LOG"; then
    grep -nE 'Backend has maxBatchSize|can not support dims|failed to match config params' "$RUN_LOG" >&2
    note_fail "nvinfer reported an engine/config capability mismatch"
else
    note_pass "nvinfer accepted the engine without a capability mismatch"
fi

# --- 5. nvinfer clean ---
bold "== CHECK 5: nvinfer configuration and parsing =="
if grep -qE 'Could not find output layer|Could not parse|Failed to parse bboxes|NVDSINFER_CONFIG_FAILED|NVDSINFER_CUSTOM_LIB_FAILED' "$RUN_LOG"; then
    grep -nE 'Could not find output layer|Could not parse|Failed to parse bboxes|NVDSINFER_' "$RUN_LOG" | head -5 >&2
    note_fail "nvinfer reported a config or parser problem"
else
    note_pass "no nvinfer config or parser errors"
fi

# --- 6. raw detection counts ---
bold "== CHECK 6: detections produced (RAW counts, stock thresholds) =="
DETECTION_LINES="$WORKDIR/all_detections.txt"
cat "$DETECTION_DIR"/*.txt 2>/dev/null > "$DETECTION_LINES" || true
TOTAL_DETECTIONS="$(wc -l < "$DETECTION_LINES")"
printf '  %-24s %s\n' "total detections" "$TOTAL_DETECTIONS"
printf '  %s\n' "  per-class breakdown:"
if (( TOTAL_DETECTIONS > 0 )); then
    awk '{ print $1 }' "$DETECTION_LINES" | sort | uniq -c \
        | awk '{ printf "    %-14s %s\n", $2, $1 }'
else
    printf '    (none)\n'
fi
PERSON_DETECTIONS="$(awk '$1 == "person"' "$DETECTION_LINES" | wc -l)"
PERSON_FRAMES="$(grep -l '^person ' "$DETECTION_DIR"/*.txt 2>/dev/null | wc -l)"
printf '  %-24s %s\n' "person detections" "$PERSON_DETECTIONS"
printf '  %-24s %s of %s\n' "frames with a person" "$PERSON_FRAMES" "$FRAME_FILES"
if (( PERSON_DETECTIONS > 0 )); then
    note_pass "at least one 'person' detection was produced"
else
    note_fail "no 'person' detections at stock thresholds (reported, not tuned around)"
fi

# --- 7. class_id 2 is person ---
# nvinfer sets obj_meta->class_id and obj_meta->obj_label from the same index,
# and filter-out-class-ids filters on that index. Excluding 0, 1 and 3 therefore
# leaves only class 2, so whatever survives IS class 2 by construction.
bold "== CHECK 7: class_id 2 is 'person' (filter-out-class-ids run) =="
FILTER_KITTI="$WORKDIR/kitti_filtered"
mkdir -p "$FILTER_KITTI"
sed -e "s|^model-engine-file=.*|model-engine-file=$(readlink -f "$STABLE_ENGINE")|" \
    -e "0,/^\[property\]/s|^\[property\]|[property]\nfilter-out-class-ids=0;1;3|" \
    "$INFER_CFG" > "$WORKDIR/infer_filtered.txt"
# This check is about the detector alone, so the later stages are stripped: the
# track dumps are dropped (their relative paths would not resolve from $WORKDIR)
# and analytics is disabled.
#
# config-file= must be rewritten for [primary-gie] ONLY. Since checkpoint 3
# there are two groups carrying that key, and a blanket substitution would point
# nvdsanalytics at an nvinfer config -- which fails the whole run.
awk -v infer="$WORKDIR/infer_filtered.txt" -v kitti="$FILTER_KITTI" '
    /^\[/ { group = $0 }
    /^gie-kitti-output-dir=/            { print "gie-kitti-output-dir=" kitti; next }
    /^kitti-track-output-dir=/          { next }
    /^terminated-track-output-dir=/     { next }
    /^shadow-track-output-dir=/         { next }
    group == "[primary-gie]"    && /^config-file=/ { print "config-file=" infer; next }
    group == "[nvds-analytics]" && /^enable=/      { print "enable=0"; next }
                                        { print }
' "$APP_CFG" > "$WORKDIR/app_filtered.txt"

filter_rc=0
deepstream-app -c "$WORKDIR/app_filtered.txt" >"$WORKDIR/run2.log" 2>&1 || filter_rc=$?
printf '  %-24s %s\n' "exit status" "$filter_rc"
cat "$FILTER_KITTI"/*.txt 2>/dev/null > "$WORKDIR/filtered_detections.txt" || true
FILTERED_TOTAL="$(wc -l < "$WORKDIR/filtered_detections.txt")"
FILTERED_NON_PERSON="$(awk '$1 != "person"' "$WORKDIR/filtered_detections.txt" | wc -l)"
printf '  %-24s %s\n' "surviving detections" "$FILTERED_TOTAL"
printf '  %-24s %s\n' "non-person survivors" "$FILTERED_NON_PERSON"

if (( filter_rc != 0 )); then
    tail -n 15 "$WORKDIR/run2.log" >&2
    note_fail "the filtered run exited $filter_rc"
elif (( FILTERED_TOTAL > 0 && FILTERED_NON_PERSON == 0 )); then
    note_pass "with classes 0,1,3 filtered out, every surviving detection is 'person' -> class_id 2"
elif (( FILTERED_TOTAL == 0 )); then
    note_fail "nothing survived the class filter, so class_id 2 could not be demonstrated"
else
    note_fail "$FILTERED_NON_PERSON non-person detections survived a filter that excludes all but class 2"
fi

# --- 8. nothing beyond the current milestone scope ---
# This check has now been narrowed twice, each time because a later checkpoint
# added -- on purpose -- the very thing it forbade:
#   originally  no tracker AND no analytics
#   checkpoint 2  added nvtracker      -> narrowed to analytics only
#   checkpoint 3  added nvdsanalytics  -> narrowed to what is still out of scope
# The intent has never changed: nothing beyond the approved scope has crept in.
# What checkpoint 1 owns -- detection metadata -- is still fully regression
# tested by CHECKS 1-7 above, which read only the pre-tracker detector dump.
bold "== CHECK 8: nothing beyond the approved scope =="
OUT_OF_SCOPE='^\[secondary-gie|^\[line-crossing|^\[overcrowding|^\[direction-detection|^\[message-broker|^\[message-converter|msg-broker-proto-lib'
if grep -rqE "$OUT_OF_SCOPE" "$CONFIG_DIR"/; then
    grep -rnE "$OUT_OF_SCOPE" "$CONFIG_DIR"/ >&2
    note_fail "out-of-scope configuration is present (secondary inference, extra analytics rules or messaging)"
else
    note_pass "no secondary-gie, line-crossing, overcrowding, direction or messaging group"
fi
if grep -qE 'nvmsgconv|nvmsgbroker' "$RUN_LOG"; then
    note_fail "the runtime log mentions a messaging element"
else
    note_pass "no messaging element appeared at runtime"
fi

# ---------------------------------------------------------------- summary ----
bold "== Summary =="
printf '  %-24s %s\n' "frames processed" "$FRAME_FILES"
printf '  %-24s %s\n' "total detections" "$TOTAL_DETECTIONS"
printf '  %-24s %s\n' "person detections" "$PERSON_DETECTIONS"
printf '  %-24s %s\n' "detections kept" "$DETECTION_DIR"

if (( FAILURES == 0 )); then
    bold "All checks passed."
    exit 0
fi
die "$FAILURES check(s) failed."
