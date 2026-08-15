#!/usr/bin/env bash
# verify_events.sh - Milestone 9.2: prove that the structured surveillance event
#                    stream is correct, transition-based and bounded.
#
# WHAT THIS ASSERTS, AND WHY IT IS A SEPARATE SCRIPT
# --------------------------------------------------
# Milestone 9.2 adds one thing: JSON Lines zone-transition events written by
# tools/analytics_probe.cpp from the SAME nvdsanalytics metadata the restricted
# zone has always used. verify_zone.sh and verify_triton.sh are the statements of
# record for Milestones 5 and 7 and are deliberately not touched; this script
# adds a claim rather than redefining one.
#
# THE CROSS-CHECK IS THE POINT
# ----------------------------
# The event stream and scripts/analyze_zone.py derive the SAME entry/exit
# interval by two independent routes:
#
#   events        C++ per-frame edge detection on (object_id, roi_label),
#                 emitted live during the run
#   analyze_zone  Python, offline, reading the per-frame dump files afterwards
#
# Neither parses the other. If the C++ transition logic were wrong, the Python
# recomputation would disagree and this script fails. That is why CHECK 5 exists
# and why it is not simply "the file says 109 so 109 is right".
#
# FRAME CONVENTION -- read this before changing an expected value
#   zone_enter.frame_number = 109   first frame inside
#   zone_exit.frame_number  = 183   LAST frame inside, not the first frame
#                                   outside. 183 - 109 + 1 = 75 frames, which is
#                                   the 109/75/183 convention every earlier
#                                   milestone already records.
#
# Runs:
#   RUN 1  analytics_probe in the M7 container, --events-output   (fresh, --rm)
#
# What it proves:
#   1  the run completed: exit 0, all frames, no element error
#   2  the event file exists, is non-empty, and every line is valid JSON
#   3  the schema is right: required keys present with the right types
#   4  the events are exactly the expected transitions -- and no per-frame spam
#   5  the interval agrees with analyze_zone.py, computed independently
#   6  deployment hygiene: no container, no orphan, bounded disk
#
# Usage:  ./scripts/verify_events.sh

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ds_common.sh"

IMAGE_NAME="${IMAGE_NAME:-video-surveillance-deepstream}"
IMAGE_TAG="${IMAGE_TAG:-m7-triton}"
IMAGE="$IMAGE_NAME:$IMAGE_TAG"

# The frozen restricted-zone invariants. These are Milestone 5's result,
# re-confirmed by Milestones 7 and 8.3; Milestone 9.2 must reproduce them, not
# redefine them.
EXPECT_ZONE="RF"
EXPECT_ENTER_FRAME=109
EXPECT_EXIT_FRAME=183
EXPECT_FRAMES_INSIDE=75
EXPECT_CLASS="person"
# 75 / 29.97 = 2.5025 s. Compared with tolerance, never as text: the value is
# derived from PTS at run time and is a float.
EXPECT_DURATION_S=2.5025
DURATION_TOL_S=0.05

while (( $# > 0 )); do
    case "$1" in
        -h|--help) sed -n '2,45p' "$0"; exit 0 ;;
        *) die "Unknown option '$1'. Try --help." ;;
    esac
done

require_tools; require_analytics_config; require_triton_repo
command -v docker >/dev/null 2>&1 || die "'docker' is not in PATH."
docker info >/dev/null 2>&1 || die "Cannot talk to the Docker daemon."
docker image inspect "$IMAGE" >/dev/null 2>&1 \
    || die "Image '$IMAGE' not found. This script never builds it."
command -v python3 >/dev/null 2>&1 || die "python3 is required to validate JSON."

WORKDIR="$(mktemp -d)"
FAILURES=0
# A failing run's artifacts are the entire point; a passing run's are noise.
# Same policy as verify_triton.sh.
keep_or_clean() {
    local rc=$?
    if (( rc == 0 && ${FAILURES:-0} == 0 )); then
        rm -rf "$WORKDIR"
    else
        printf '\n  evidence retained: %s\n' "$WORKDIR" >&2
        printf '  %s\n' "run.log  events.jsonl (copy)  zone_verdict.txt" >&2
    fi
}
trap keep_or_clean EXIT
note_pass() { printf '  PASS  %s\n' "$*"; }
note_fail() { printf '  FAIL  %s\n' "$*"; FAILURES=$(( FAILURES + 1 )); }

DISK_BEFORE_KB="$(df -Pk "$REPO_ROOT" | awk 'NR==2 { print $4 }')"

bold "== Environment =="
printf '  %-32s %s\n' "image" "$IMAGE"
printf '  %-32s %s\n' "probe (host build)" "$PROBE_BIN"
printf '  %-32s %s\n' "event file" "$EVENTS_FILE"
printf '  %-32s %s\n' "expected interval" \
    "enter $EXPECT_ENTER_FRAME, $EXPECT_FRAMES_INSIDE frames, exit $EXPECT_EXIT_FRAME"

# --- 1 -------------------------------------------------------------- run ---
bold "== CHECK 1: a fresh container run completes =="
run_rc=0
./scripts/run_container.sh --events --triton >"$WORKDIR/run.log" 2>&1 || run_rc=$?
printf '  %-32s %s\n' "exit status" "$run_rc"
(( run_rc == 0 )) && note_pass "analytics_probe exited 0" \
    || { tail -n 20 "$WORKDIR/run.log" >&2; note_fail "the run exited $run_rc"; }

EXPECTED_FRAMES="$(video_frame_count "$(resolve_video)")"
FRAMES_LINE="$(grep -c "^frames written: $EXPECTED_FRAMES\$" "$WORKDIR/run.log")" \
    || FRAMES_LINE=0
(( FRAMES_LINE == 1 )) \
    && note_pass "all $EXPECTED_FRAMES frames reached nvdsanalytics" \
    || note_fail "the probe did not report $EXPECTED_FRAMES frames"

# The probe turns any element error into a non-zero exit, but assert the log
# too: an error that did not change the exit status is exactly the kind of
# failure a verification is supposed to catch.
if grep -qE '^ERROR from |ERROR: ' "$WORKDIR/run.log"; then
    grep -E '^ERROR from |ERROR: ' "$WORKDIR/run.log" | head -3 >&2
    note_fail "the run log reports an error"
else
    note_pass "no element errors in the run log"
fi

# --- 2 ------------------------------------------------------------ file ----
bold "== CHECK 2: the event file exists and is valid JSON Lines =="
if [[ ! -f "$EVENTS_FILE" ]]; then
    note_fail "no event file at $EVENTS_FILE"
else
    cp "$EVENTS_FILE" "$WORKDIR/events.jsonl"
    EV_BYTES="$(wc -c <"$EVENTS_FILE")"
    EV_LINES="$(wc -l <"$EVENTS_FILE")"
    printf '  %-32s %s bytes, %s lines\n' "event file" "$EV_BYTES" "$EV_LINES"
    (( EV_BYTES > 0 )) && note_pass "event file is non-empty" \
        || note_fail "event file is empty"

    # A real parser, not a regex: a regex that "looks like JSON" is how invalid
    # JSON reaches a consumer.
    if python3 -c '
import json, sys
bad = 0
with open(sys.argv[1]) as fh:
    for i, line in enumerate(fh, 1):
        if not line.strip():
            print("line %d is blank" % i); bad += 1; continue
        try:
            json.loads(line)
        except Exception as e:
            print("line %d is not valid JSON: %s" % (i, e)); bad += 1
sys.exit(1 if bad else 0)
' "$EVENTS_FILE"; then
        note_pass "every line parses as JSON"
    else
        note_fail "the event file contains invalid JSON"
    fi
fi

# --- 3 ---------------------------------------------------------- schema ----
bold "== CHECK 3: schema and types =="
if [[ -f "$EVENTS_FILE" ]] && python3 -c '
import json, sys

REQUIRED = {"event": str, "event_time_utc": str, "frame_number": int,
            "stream_time_seconds": float, "zone": str, "track_id": int,
            "class": str, "occupancy": int}
EXIT_EXTRA = {"frames_inside": int, "duration_seconds": float}

bad = 0
with open(sys.argv[1]) as fh:
    for i, line in enumerate(fh, 1):
        e = json.loads(line)
        for k, t in REQUIRED.items():
            if k not in e:
                print("line %d missing %r" % (i, k)); bad += 1; continue
            v = e[k]
            # bool is a subclass of int; an event count must not be True.
            if isinstance(v, bool) or not isinstance(v, (int, float) if t is float else t):
                print("line %d: %r is %r, expected %s" % (i, k, v, t.__name__)); bad += 1
        if e.get("event") == "zone_exit":
            for k, t in EXIT_EXTRA.items():
                if k not in e:
                    print("line %d: zone_exit missing %r" % (i, k)); bad += 1
        # Timestamp must be the schema we documented, not merely a string.
        ts = e.get("event_time_utc", "")
        if not (len(ts) == 24 and ts[10] == "T" and ts.endswith("Z")):
            print("line %d: event_time_utc %r is not ISO-8601 UTC ms" % (i, ts)); bad += 1
sys.exit(1 if bad else 0)
' "$EVENTS_FILE"; then
    note_pass "all events carry the required keys with the right types"
else
    note_fail "schema validation failed"
fi

# --- 4 ---------------------------------------------------------- events ----
bold "== CHECK 4: exactly the expected transitions, and no per-frame spam =="
if [[ -f "$EVENTS_FILE" ]]; then
    python3 - "$EVENTS_FILE" >"$WORKDIR/events.txt" <<'PY'
import json, sys
from collections import Counter

events = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
kinds = Counter(e["event"] for e in events)
print("total=%d" % len(events))
for k in sorted(kinds):
    print("count_%s=%d" % (k, kinds[k]))
for e in events:
    if e["event"] == "zone_enter":
        print("enter_frame=%d" % e["frame_number"])
        print("enter_zone=%s" % e["zone"])
        print("enter_track=%d" % e["track_id"])
        print("enter_class=%s" % e["class"])
        print("enter_occupancy=%d" % e["occupancy"])
    if e["event"] == "zone_exit":
        print("exit_frame=%d" % e["frame_number"])
        print("exit_track=%d" % e["track_id"])
        print("exit_frames_inside=%d" % e["frames_inside"])
        print("exit_duration=%.4f" % e.get("duration_seconds", -1))
        print("exit_reason=%s" % e.get("exit_reason", "none"))
PY
    eget() { sed -n "s/^$1=//p" "$WORKDIR/events.txt"; }

    TOTAL="$(eget total)"
    N_ENTER="$(eget count_zone_enter)"; N_ENTER="${N_ENTER:-0}"
    N_EXIT="$(eget count_zone_exit)";   N_EXIT="${N_EXIT:-0}"
    printf '  %-32s %s\n' "total events" "$TOTAL"
    printf '  %-32s %s\n' "zone_enter" "$N_ENTER"
    printf '  %-32s %s\n' "zone_exit" "$N_EXIT"

    [[ "$N_ENTER" == "1" && "$N_EXIT" == "1" ]] \
        && note_pass "exactly one zone_enter and one zone_exit" \
        || note_fail "expected 1 enter and 1 exit, got $N_ENTER and $N_EXIT"

    # The anti-spam assertion, stated as a property rather than a count: the
    # event stream must be O(transitions), never O(frames). 288 frames with 75
    # inside would give 75+ events under a per-frame model.
    if (( TOTAL <= 10 )); then
        note_pass "event count $TOTAL is O(transitions), not O(frames) -- no per-frame spam"
    else
        note_fail "$TOTAL events for one interval looks like per-frame state, not transitions"
    fi
    if grep -qE '"event":"zone_inside"|"event":"person_detected"' "$EVENTS_FILE"; then
        note_fail "per-frame state events are present in the stream"
    else
        note_pass "no zone_inside / person_detected per-frame events"
    fi

    printf '  %-32s %s (expected %s)\n' "enter frame" "$(eget enter_frame)" "$EXPECT_ENTER_FRAME"
    printf '  %-32s %s (expected %s)\n' "exit frame" "$(eget exit_frame)" "$EXPECT_EXIT_FRAME"
    printf '  %-32s %s (expected %s)\n' "frames inside" "$(eget exit_frames_inside)" "$EXPECT_FRAMES_INSIDE"
    printf '  %-32s %s\n' "zone / class" "$(eget enter_zone) / $(eget enter_class)"
    printf '  %-32s %s\n' "exit reason" "$(eget exit_reason)"

    [[ "$(eget enter_frame)" == "$EXPECT_ENTER_FRAME" ]] \
        && note_pass "zone_enter at frame $EXPECT_ENTER_FRAME" \
        || note_fail "zone_enter at $(eget enter_frame), expected $EXPECT_ENTER_FRAME"
    [[ "$(eget exit_frame)" == "$EXPECT_EXIT_FRAME" ]] \
        && note_pass "zone_exit at frame $EXPECT_EXIT_FRAME (last inside frame)" \
        || note_fail "zone_exit at $(eget exit_frame), expected $EXPECT_EXIT_FRAME"
    [[ "$(eget exit_frames_inside)" == "$EXPECT_FRAMES_INSIDE" ]] \
        && note_pass "frames_inside $EXPECT_FRAMES_INSIDE" \
        || note_fail "frames_inside $(eget exit_frames_inside), expected $EXPECT_FRAMES_INSIDE"
    [[ "$(eget enter_zone)" == "$EXPECT_ZONE" ]] \
        && note_pass "zone label '$EXPECT_ZONE', taken from the analytics config" \
        || note_fail "zone label $(eget enter_zone), expected $EXPECT_ZONE"
    [[ "$(eget enter_class)" == "$EXPECT_CLASS" ]] \
        && note_pass "class '$EXPECT_CLASS'" \
        || note_fail "class $(eget enter_class), expected $EXPECT_CLASS"
    [[ "$(eget enter_track)" == "$(eget exit_track)" ]] \
        && note_pass "enter and exit carry the same track_id ($(eget enter_track))" \
        || note_fail "track_id differs between enter and exit"
    [[ "$(eget exit_reason)" == "left_zone" ]] \
        && note_pass "exit_reason 'left_zone' -- the track was still tracked after leaving" \
        || note_fail "exit_reason $(eget exit_reason), expected left_zone"

    # Float compared numerically with a tolerance, never as text.
    if python3 -c "
import sys
got, want, tol = float('$(eget exit_duration)'), $EXPECT_DURATION_S, $DURATION_TOL_S
sys.exit(0 if abs(got - want) <= tol else 1)"; then
        note_pass "duration_seconds $(eget exit_duration) within ±$DURATION_TOL_S of $EXPECT_DURATION_S"
    else
        note_fail "duration_seconds $(eget exit_duration), expected $EXPECT_DURATION_S ±$DURATION_TOL_S"
    fi
else
    note_fail "no event file to inspect"
fi

# --- 5 ----------------------------------------------------- cross-check ----
bold "== CHECK 5: independent cross-check against analyze_zone.py =="
# analyze_zone.py reads the per-frame dump files and recomputes the interval in
# Python, offline. The event stream was produced by C++ edge detection during
# the run. Two routes, one answer -- and neither reads the other's output.
Z="$WORKDIR/zone_verdict.txt"
python3 "$REPO_ROOT/scripts/analyze_zone.py" --zone "$ZONE_DIR" --tracks "$TRACK_DIR" \
    --config "$(analytics_config)" --verdict "$Z" >"$WORKDIR/zone_report.txt"
zget() { sed -n "s/^$1=//p" "$Z"; }
printf '  %-32s %s\n' "analyze_zone entry" "$(zget ds_entry)"
printf '  %-32s %s\n' "analyze_zone exit" "$(zget ds_exit)"
printf '  %-32s %s\n' "analyze_zone frames inside" "$(zget ds_frames_inside)"
printf '  %-32s %s\n' "analyze_zone runs" "$(zget ds_runs)"

if [[ -f "$EVENTS_FILE" ]]; then
    ok=1
    [[ "$(eget enter_frame)" == "$(zget ds_entry)" ]] || ok=0
    [[ "$(eget exit_frame)" == "$(zget ds_exit)" ]] || ok=0
    [[ "$(eget exit_frames_inside)" == "$(zget ds_frames_inside)" ]] || ok=0
    (( ok == 1 )) \
        && note_pass "the event stream and analyze_zone.py agree exactly on entry, exit and duration" \
        || note_fail "the event stream disagrees with the independent recomputation"
    [[ "$(zget ds_runs)" == "1" ]] \
        && note_pass "one contiguous interval, so one enter/exit pair is the complete story" \
        || note_fail "analyze_zone reports $(zget ds_runs) runs but the stream has $N_ENTER enter events"
fi

# --- 6 --------------------------------------------------------- hygiene ----
bold "== CHECK 6: deployment hygiene =="
LEFTOVER="$(docker ps -aq | wc -l)"
(( LEFTOVER == 0 )) && note_pass "no container left behind (docker ps -a is empty)" \
    || note_fail "$LEFTOVER container(s) still exist"

ORPHANS="$(ps -eo comm= | sort -u | grep -cE '^(deepstream-app|analytics_probe)$')" || ORPHANS=0
(( ORPHANS == 0 )) && note_pass "no orphan deepstream-app or analytics_probe" \
    || note_fail "$ORPHANS orphan process(es)"

DISK_AFTER_KB="$(df -Pk "$REPO_ROOT" | awk 'NR==2 { print $4 }')"
DELTA_KB=$(( DISK_BEFORE_KB - DISK_AFTER_KB ))
printf '  %-32s %s KB\n' "disk delta" "$DELTA_KB"
# The event file is transitions, not frames: hundreds of bytes. A megabyte would
# mean the anti-spam property had failed somewhere this script did not look.
if [[ -f "$EVENTS_FILE" ]] && (( $(wc -c <"$EVENTS_FILE") < 65536 )); then
    note_pass "event file is under 64 KB -- bounded by design, truncated per run"
else
    note_fail "event file is unexpectedly large"
fi

# Filtered by find itself rather than by a grep. `find | grep -v | wc -l` looks
# harmless and is not: grep -v exits 1 when it emits no lines, and under
# `set -o pipefail` that aborts the script just as it is about to report a pass.
# Found by this script failing at exactly that line with every check green.
#
# AMENDED 2026-08-15 (Milestone 10.3). demo/ is excluded alongside media/. When
# this check was written media/ was the repository's only legitimate home for a
# video file; M10.2 added demo/ for the capstone demo capture, which is a
# screen recording and a git-ignored submission artifact -- not something any
# pipeline in this project writes. The property under test is unchanged and
# still enforced: the EVENT PIPELINE must produce no video. It cannot hide one,
# because deepstream-app and analytics_probe write only under models/, which is
# still fully in scope here. Without this exclusion the check fails on the
# deliverable it was never meant to police.
VIDEOS="$(find "$REPO_ROOT" -not -path "$REPO_ROOT/media/*" -not -path "$REPO_ROOT/demo/*" \
    \( -name '*.mp4' -o -name '*.mkv' -o -name '*.h264' \) 2>/dev/null | wc -l)"
(( VIDEOS == 0 )) && note_pass "no output video produced" \
    || note_fail "$VIDEOS video file(s) appeared"

# --- verdict ----------------------------------------------------------------
printf '\n'
if (( FAILURES == 0 )); then
    bold "== Milestone 9.2 event stream VERIFIED =="
    printf '  %s\n' \
        "zone_enter frame $(eget enter_frame), zone_exit frame $(eget exit_frame), $(eget exit_frames_inside) frames inside" \
        "cross-checked against analyze_zone.py, which recomputed the same interval independently" \
        "transitions only: $(eget total) events for $EXPECTED_FRAMES frames" \
        "" \
        "This run used --network none: event generation needs no broker and no" \
        "network. MQTT delivery of these same payloads is Milestone 9.3 and is" \
        "verified separately by scripts/verify_mqtt.sh."
    exit 0
else
    bold "== $FAILURES CHECK(S) FAILED =="
    exit 1
fi
