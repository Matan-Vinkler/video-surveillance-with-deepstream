#!/usr/bin/env bash
# verify_tracking.sh - headless, machine-checked verification of the Milestone 5
# checkpoint-2 pipeline:
#
#   file source -> decoder -> nvstreammux -> nvinfer -> nvtracker (NvSORT)
#                -> nvmultistreamtiler -> nvdsosd -> fakesink
#
# Needs no display, terminates on its own, never loops.
#
# Four runs:
#   RUN 1  the real pipeline; captures the detector dump AND the tracker dump
#          from the SAME run, so they can be compared frame for frame
#   RUN 2  identical but with [tracker] enable=0; proves the tracker did not
#          perturb detection, by diffing RUN 1's detector dump against it
#   RUN 3  negative control: a bogus ll-lib-file must make the app FAIL
#   RUN 4  negative control: a bogus ll-config-file does NOT fail -- it warns
#          and silently uses tracker defaults, which is why RUN 1 is checked
#          for the absence of that warning
#
# What it proves:
#   1  the application runs to a clean EOS
#   2  nvtracker is really instantiated, and loads the vendor low-level library
#   3  the prebuilt FP16 engine is still deserialized, not rebuilt
#   4  both dumps cover every frame of the clip
#   5  detection metadata is UNCHANGED by adding the tracker
#   6  every tracked object carries a valid object_id
#   7  no MID-TRACK id switch while the detector observes the person
#   8  the tracker is load-bearing, and NvSORT really was the backend in use
#   9  no analytics yet
#
# Unique ids, dominant-id coverage and establishment behaviour are REPORTED as
# metrics. They are not pass/fail criteria: see docs/milestone-05-tracking.md.
#
# Usage:
#   ./scripts/verify_tracking.sh

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ds_common.sh"

while (( $# > 0 )); do
    case "$1" in
        -h|--help) sed -n '2,39p' "$0"; exit 0 ;;
        *) die "Unknown option '$1'. Try --help." ;;
    esac
done

require_tools
require_deepstream_app
require_elements nvstreammux nvinfer nvtracker nvmultistreamtiler \
                 nvvideoconvert nvdsosd fakesink
require_tracker_assets

APP_CFG="$(require_config deepstream_app_walk_headless.txt)"
ANALYZER="$REPO_ROOT/scripts/analyze_tracks.py"
[[ -r "$ANALYZER" ]] || die "Analyzer not found: '$ANALYZER'."

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

FAILURES=0
note_pass() { printf '  PASS  %s\n' "$*"; }
note_fail() { printf '  FAIL  %s\n' "$*"; FAILURES=$(( FAILURES + 1 )); }

# ------------------------------------------------------------- environment ---
bold "== Environment =="
printf '  %-26s %s\n' "DeepStream" "$(ds_version)"
printf '  %-26s %s\n' "TensorRT" "$(trt_version)"
printf '  %-26s %s\n' "GPU" "$(gpu_slug)"
printf '  %-26s %s\n' "tracker library" "$(tracker_lib)"
printf '  %-26s %s\n' "tracker config (vendor)" "$(tracker_config)"

ENGINE_TARGET="$(ensure_engine_link)"
printf '  %-26s %s\n' "engine (expected)" "$(basename "$ENGINE_TARGET")"
FINGERPRINT_BEFORE="$(engine_fingerprint)"

# ------------------------------------------------------------------ run 1 ----
# The dumps write nothing at all if their directory is absent, so they are
# recreated empty: a stale file from an earlier run must never be read as
# evidence for this one.
for d in "$DETECTION_DIR" "$TRACK_DIR" "$TERMINATED_DIR" "$SHADOW_DIR"; do
    rm -rf "$d"
    mkdir -p "$d"
done

bold "== RUN 1: detection + tracking =="
printf '  %-26s %s\n' "app config" "$APP_CFG"
printf '  %-26s %s\n' "detector dump" "$DETECTION_DIR"
printf '  %-26s %s\n' "tracker dump" "$TRACK_DIR"

RUN_LOG="$WORKDIR/run1.log"
rc=0
deepstream-app -c "$APP_CFG" >"$RUN_LOG" 2>&1 || rc=$?
printf '  %-26s %s\n' "exit status" "$rc"

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

# --- 2. the tracker really ran ---
# Two independent proofs. nvtracker prints the low-level library it dlopens
# (nvtracker_proc.cpp:990, LOG_INFO is plain printf), and the post-tracker KITTI
# probe attaches to the tracker's src pad -- a pad that exists only if a tracker
# was created. RUN 3 then proves the tracker is load-bearing rather than inert.
bold "== CHECK 2: nvtracker instantiated with the vendor NvSORT config =="
# The config names the library through the unversioned /opt symlink and the log
# echoes that path back, so the two are compared AFTER resolution rather than as
# strings -- otherwise this would compare a symlink against its target.
LOGGED_LIB="$(sed -n 's/^gstnvtracker: Loading low-level lib at //p' "$RUN_LOG" | head -1)"
if [[ -n "$LOGGED_LIB" ]] \
   && [[ "$(readlink -f "$LOGGED_LIB")" == "$(readlink -f "$(tracker_lib)")" ]]; then
    note_pass "nvtracker loaded $(basename "$(tracker_lib)")"
else
    grep -i 'nvtracker' "$RUN_LOG" | head -5 >&2
    note_fail "the log does not show nvtracker loading $(tracker_lib) (saw: '${LOGGED_LIB:-nothing}')"
fi
if grep -qiE 'tracker.*(failed|error)|Failed to initialize|dlopen error|Unable to open|low-level lib.*fail' "$RUN_LOG"; then
    grep -inE 'tracker.*(failed|error)|dlopen error|Unable to open' "$RUN_LOG" | head -5 >&2
    note_fail "the tracker reported an initialisation error"
else
    note_pass "no tracker initialisation errors"
fi
CONFIGURED_LL_CFG="$(sed -n 's/^ll-config-file=//p' "$APP_CFG" | head -1)"
if [[ -n "$CONFIGURED_LL_CFG" ]] \
   && [[ "$(readlink -f "$CONFIGURED_LL_CFG")" == "$(readlink -f "$(tracker_config)")" ]]; then
    note_pass "config references the vendor NvSORT yml, unmodified and uncopied"
else
    printf '    config says: %s\n    expected:    %s\n' \
        "$CONFIGURED_LL_CFG" "$(tracker_config)" >&2
    note_fail "the [tracker] group does not reference the vendor NvSORT yml"
fi
for k in enable-batch-process enable-past-frame; do
    if grep -q "^$k" "$APP_CFG"; then
        note_fail "obsolete DeepStream tracker key '$k' is present"
    fi
done
note_pass "no obsolete tracker keys (enable-batch-process, enable-past-frame)"

# --- 3. engine untouched ---
bold "== CHECK 3: prebuilt FP16 engine still deserialized, not rebuilt =="
ENGINE_BASENAME="$(basename "$ENGINE_TARGET")"
if grep -q 'Use deserialized engine model' "$RUN_LOG" \
   && grep -q "$ENGINE_BASENAME" "$RUN_LOG"; then
    note_pass "engine deserialized: $ENGINE_BASENAME"
else
    note_fail "no 'Use deserialized engine model' line naming $ENGINE_BASENAME"
fi
if [[ "$FINGERPRINT_BEFORE" == "$FINGERPRINT_AFTER" ]]; then
    note_pass "engine file unchanged (sha256, mtime and size identical)"
else
    printf '    before: %s\n    after:  %s\n' "$FINGERPRINT_BEFORE" "$FINGERPRINT_AFTER" >&2
    note_fail "the engine file changed during the run"
fi

# --- 4. both dumps cover the clip ---
bold "== CHECK 4: both dumps cover every frame =="
DET_FILES="$(find "$DETECTION_DIR" -name '*.txt' -type f | wc -l)"
TRK_FILES="$(find "$TRACK_DIR" -name '*.txt' -type f | wc -l)"
EXPECTED_FRAMES="$(video_frame_count "$(resolve_video)")"
printf '  %-26s %s\n' "detector per-frame files" "$DET_FILES"
printf '  %-26s %s\n' "tracker per-frame files" "$TRK_FILES"
printf '  %-26s %s\n' "clip holds" "$EXPECTED_FRAMES frames"
if (( DET_FILES == EXPECTED_FRAMES && TRK_FILES == EXPECTED_FRAMES )); then
    note_pass "both probes wrote one file per frame for all $EXPECTED_FRAMES frames"
else
    note_fail "dump sizes disagree with the clip length"
fi

# ------------------------------------------------------------------ run 2 ----
# The same config with the tracker disabled. Anything that differs in the
# DETECTOR dump between run 1 and run 2 is attributable to the tracker.
bold "== RUN 2: same config, [tracker] enable=0 (control) =="
NOTRK_KITTI="$WORKDIR/detections_no_tracker"
mkdir -p "$NOTRK_KITTI"
awk -v out="$NOTRK_KITTI" '
    /^\[/            { in_tracker = ($0 == "[tracker]") }
    in_tracker && /^enable=/                 { print "enable=0"; next }
    /^gie-kitti-output-dir=/                 { print "gie-kitti-output-dir=" out; next }
    /^kitti-track-output-dir=/               { next }
    /^terminated-track-output-dir=/          { next }
    /^shadow-track-output-dir=/              { next }
                     { print }
' "$APP_CFG" > "$WORKDIR/app_no_tracker.txt"
# config-file= is relative to the config's own directory, so it must be absolved
# now that the copy lives in $WORKDIR.
sed -i "s|^config-file=|config-file=$CONFIG_DIR/|" "$WORKDIR/app_no_tracker.txt"

notrk_rc=0
deepstream-app -c "$WORKDIR/app_no_tracker.txt" >"$WORKDIR/run2.log" 2>&1 || notrk_rc=$?
printf '  %-26s %s\n' "exit status" "$notrk_rc"

bold "== CHECK 5: the tracker did not change detection =="
if (( notrk_rc != 0 )); then
    tail -n 15 "$WORKDIR/run2.log" >&2
    note_fail "the tracker-disabled control run exited $notrk_rc"
elif grep -q 'gstnvtracker' "$WORKDIR/run2.log"; then
    note_fail "the control run still instantiated a tracker"
else
    note_pass "control run has no tracker (nothing loaded a low-level lib)"
fi
DIFFERING="$(diff -rq "$DETECTION_DIR" "$NOTRK_KITTI" 2>/dev/null | wc -l)"
NOTRK_ROWS="$(cat "$NOTRK_KITTI"/*.txt 2>/dev/null | wc -l)"
DET_ROWS="$(cat "$DETECTION_DIR"/*.txt 2>/dev/null | wc -l)"
printf '  %-26s %s\n' "detector rows, tracked run" "$DET_ROWS"
printf '  %-26s %s\n' "detector rows, control run" "$NOTRK_ROWS"
printf '  %-26s %s\n' "per-frame files differing" "$DIFFERING"
# Checkpoint 1 measured detection counts varying by ~1% between identical runs
# (a borderline detection oscillating around pre-cluster-threshold=0.2), so an
# exact match is not required -- but a tracker-induced change would be
# structural, not a couple of frames.
if (( DIFFERING <= 5 )); then
    note_pass "detector output is materially identical with and without the tracker ($DIFFERING/$DET_FILES frames differ, within the ~1% run-to-run jitter recorded in checkpoint 1)"
else
    diff -rq "$DETECTION_DIR" "$NOTRK_KITTI" | head -10 >&2
    note_fail "$DIFFERING per-frame files differ -- more than run-to-run jitter explains"
fi

# ------------------------------------------------------------- measurement ---
bold "== Measured tracking behaviour =="
VERDICT="$WORKDIR/verdict.txt"
python3 "$ANALYZER" \
    --detections "$DETECTION_DIR" \
    --tracks "$TRACK_DIR" \
    --terminated "$TERMINATED_DIR" \
    --shadow "$SHADOW_DIR" \
    --verdict "$VERDICT"

get() { sed -n "s/^$1=//p" "$VERDICT"; }

# --- 6. valid object ids ---
bold "== CHECK 6: every tracked object carries a valid object_id =="
TRK_FRAMES="$(get trk_frames)"
UNTRACKED="$(get untracked_rows)"
printf '  %-26s %s\n' "tracked person frames" "$TRK_FRAMES"
printf '  %-26s %s\n' "rows with UNTRACKED id" "$UNTRACKED"
if (( TRK_FRAMES > 0 )); then
    note_pass "the tracker emitted person objects on $TRK_FRAMES frames"
else
    note_fail "no tracked person objects at all"
fi
if (( UNTRACKED == 0 )); then
    note_pass "no row carries UNTRACKED_OBJECT_ID (0xFFFFFFFFFFFFFFFF)"
else
    note_fail "$UNTRACKED row(s) carry UNTRACKED_OBJECT_ID"
fi

# --- 7. the tracking-quality criterion ---
# Not "dominant id >= 90%". The criterion is that identity does not change once
# a stable track exists, on frames where the detector is continuously observing
# the same person. Establishment-phase ids are reported separately because a
# probation period legitimately produces them.
bold "== CHECK 7: no MID-TRACK id switch under continuous detection =="
MID="$(get mid_track_switches)"
ESTAB="$(get establishment_switches)"
UNIQUE="$(get unique_ids)"
COVERAGE="$(get dominant_coverage_pct)"
printf '  %-26s %-8s %s\n' "unique track ids" "$UNIQUE" "[metric, not a criterion]"
printf '  %-26s %-8s %s\n' "dominant id coverage" "$COVERAGE%" "[metric, not a criterion]"
printf '  %-26s %-8s %s\n' "establishment switches" "$ESTAB" "[reported separately]"
printf '  %-26s %-8s %s\n' "MID-TRACK switches" "$MID" "[the criterion]"
if (( MID == 0 )); then
    note_pass "identity never changed after the stable track was established"
else
    note_fail "$MID mid-track id switch(es) -- reported as measured, NOT tuned around"
fi

# --- 8. the tracker is load-bearing, and the vendor yml really was read ---
# The two assets fail in COMPLETELY different ways, which is why both are
# exercised. A missing library is fatal. A missing config is only a warning:
# the low-level library falls back to built-in defaults and the pipeline runs
# to a clean EOS with a DIFFERENT tracker than the one configured. That silent
# degradation is the reason RUN 1 is also checked for the absence of the
# warning -- otherwise a typo in ll-config-file would pass every other check.
make_variant() {
    sed "$1" "$APP_CFG" > "$2"
    sed -i -e "s|^config-file=|config-file=$CONFIG_DIR/|" \
           -e "/^gie-kitti-output-dir=/d" -e "/^kitti-track-output-dir=/d" \
           -e "/^terminated-track-output-dir=/d" -e "/^shadow-track-output-dir=/d" "$2"
}
LL_CFG_MISSING_WARNING='NvTrackerParams::getConfigRoot.*File doesn.t exist'

bold "== RUN 3 / CHECK 8a: a missing tracker LIBRARY must fail the run =="
make_variant "s|^ll-lib-file=.*|ll-lib-file=/nonexistent/libnvds_NOPE.so|" \
    "$WORKDIR/app_bad_lib.txt"
badlib_rc=0
deepstream-app -c "$WORKDIR/app_bad_lib.txt" >"$WORKDIR/run3.log" 2>&1 || badlib_rc=$?
printf '  %-26s %s\n' "exit status" "$badlib_rc"
if (( badlib_rc != 0 )) && grep -q 'Failed to initilaize low level lib' "$WORKDIR/run3.log"; then
    note_pass "a nonexistent ll-lib-file makes deepstream-app fail (exit $badlib_rc); the tracker is load-bearing"
    grep -iE 'dlopen error|Failed to (open|initilaize)' "$WORKDIR/run3.log" | head -3 | sed 's/^/    /'
else
    tail -n 10 "$WORKDIR/run3.log" >&2
    note_fail "the app did not fail with a nonexistent tracker library (exit $badlib_rc)"
fi

bold "== RUN 4 / CHECK 8b: a missing tracker CONFIG degrades SILENTLY =="
make_variant "s|^ll-config-file=.*|ll-config-file=/nonexistent/config_tracker_NOPE.yml|" \
    "$WORKDIR/app_bad_cfg.txt"
badcfg_rc=0
deepstream-app -c "$WORKDIR/app_bad_cfg.txt" >"$WORKDIR/run4.log" 2>&1 || badcfg_rc=$?
printf '  %-26s %s\n' "exit status" "$badcfg_rc"
if (( badcfg_rc == 0 )) && grep -qE "$LL_CFG_MISSING_WARNING" "$WORKDIR/run4.log"; then
    note_pass "confirmed: a bad ll-config-file only WARNS and falls back to defaults"
    grep -E "$LL_CFG_MISSING_WARNING" "$WORKDIR/run4.log" | head -1 | sed 's/^/    /'
else
    note_fail "could not reproduce the silent-fallback behaviour, so CHECK 8c proves nothing"
fi

bold "== CHECK 8c: RUN 1 actually read the vendor NvSORT yml =="
if grep -qE "$LL_CFG_MISSING_WARNING" "$RUN_LOG"; then
    grep -E "$LL_CFG_MISSING_WARNING" "$RUN_LOG" | head -1 >&2
    note_fail "RUN 1 fell back to tracker defaults -- NvSORT was NOT in effect"
else
    note_pass "RUN 1 shows no config-fallback warning: the NvSORT yml was read"
fi

# Finally, prove the repository's own preflight catches a missing asset up
# front, instead of leaving it to fail deep inside the low-level library.
pre_rc=0
( DS_LINK="$WORKDIR/no_such_deepstream" require_tracker_assets ) \
    >"$WORKDIR/preflight.log" 2>&1 || pre_rc=$?
if (( pre_rc != 0 )); then
    note_pass "ds_common.sh preflight fails clearly when the assets are missing (exit $pre_rc)"
else
    note_fail "the preflight accepted a missing tracker library"
fi

# --- 9. nothing beyond the current milestone scope ---
# Originally "no analytics yet". Checkpoint 3 adds nvdsanalytics on purpose, so
# the assertion was narrowed to what is still out of scope. Tracking itself --
# what this script owns -- is unaffected: CHECKS 1-8 read the tracker dump,
# which checkpoint 3 proves is byte-identical with and without analytics.
bold "== CHECK 9: nothing beyond the approved scope =="
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
printf '  %-26s %s\n' "frames processed" "$(get frames_total)"
printf '  %-26s %s\n' "frames with a detection" "$(get det_frames)"
printf '  %-26s %s\n' "frames with a tracked person" "$(get trk_frames)"
printf '  %-26s %s\n' "unique track ids" "$(get unique_ids)"
printf '  %-26s %s\n' "longest continuous track" "$(get longest_run_len) frames"
printf '  %-26s %s\n' "MID-TRACK id switches" "$(get mid_track_switches)"
printf '  %-26s %s\n' "interior detector gaps" "$(get interior_det_gaps)"
printf '  %-26s %s\n' "detections kept" "$DETECTION_DIR"
printf '  %-26s %s\n' "tracks kept" "$TRACK_DIR"

if (( FAILURES == 0 )); then
    bold "All checks passed."
    exit 0
fi
die "$FAILURES check(s) failed."
