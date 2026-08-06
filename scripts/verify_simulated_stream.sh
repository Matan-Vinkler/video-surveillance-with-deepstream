#!/usr/bin/env bash
# verify_simulated_stream.sh - headless verification of the simulated camera
# stream. Needs no display and terminates on its own.
#
# It proves two separate things with two separate runs, because on this
# platform one run cannot prove both (see docs/milestone-02-video-input.md):
#
#   CHECK 1  Frame flow, bounded.  Decode exactly N frames and exit 0.
#            Bounded by fakesink num-buffers, unpaced so it finishes quickly.
#
#   CHECK 2  Real-time pacing.     Play a clip to its natural EOS twice, once
#            with sync=true and once with sync=false, and compare the wall
#            clock against the clip's real duration. Paced playback must take
#            about as long as the clip; unpaced must be far quicker.
#
# This check is always bounded and never loops, whatever the playback script
# is doing: each run decodes a fixed number of frames, or plays one clip once.
#
# Usage:
#   ./scripts/verify_simulated_stream.sh              # default 9.61 s source
#   ./scripts/verify_simulated_stream.sh --crowded    # busier 48 s source
#   ./scripts/verify_simulated_stream.sh --frames 300

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

FRAMES=150
VIDEO_ARG=""

while (( $# > 0 )); do
    case "$1" in
        --crowded) VIDEO_ARG="$CROWDED_VIDEO_NAME" ;;
        --frames)  shift; (( $# > 0 )) || die "--frames needs a value."; FRAMES="$1" ;;
        -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
        -*) die "Unknown option '$1'. Try --help." ;;
        *)  VIDEO_ARG="$1" ;;
    esac
    shift
done

[[ "$FRAMES" =~ ^[1-9][0-9]*$ ]] || die "--frames must be a positive integer, got '$FRAMES'."

require_tools
require_elements "${REQUIRED_ELEMENTS[@]}"

FRAME_VIDEO="$(resolve_video "${VIDEO_ARG:-$DEFAULT_VIDEO_NAME}")"
PACE_VIDEO="$FRAME_VIDEO"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

FAILURES=0
note_pass() { printf '  PASS  %s\n' "$*"; }
note_fail() { printf '  FAIL  %s\n' "$*"; FAILURES=$(( FAILURES + 1 )); }

# The same explicit front end as run_simulated_stream.sh, ending in a fakesink
# so that frames are really decoded and consumed but nothing is displayed.
pipeline_head() {
    printf '%s\n' \
        "filesrc location=$1" \
        "! qtdemux name=demux" \
        "demux.video_0" \
        "! queue" \
        "! h264parse" \
        "! nvv4l2decoder"
}

bold "== Environment =="
printf '  %-18s %s\n' "DeepStream" "$(ds_version)"
printf '  %-18s %s\n' "GStreamer" "$(gst-launch-1.0 --version | awk 'NR==2 { print $2 }')"
printf '  %-18s %s\n' "display" "$(find_display 2>/dev/null || echo 'none (headless)')"

# --------------------------------------------------------------- CHECK 1 ---
AVAILABLE_FRAMES="$(video_frame_count "$FRAME_VIDEO")"
if (( FRAMES > AVAILABLE_FRAMES )); then
    die "Requested $FRAMES frames but '$FRAME_VIDEO' contains only $AVAILABLE_FRAMES.
       The clip would reach end of stream first and the check could never pass.
       Use --frames $AVAILABLE_FRAMES or fewer, or --crowded for a longer source."
fi

bold "== CHECK 1: bounded frame flow ($FRAMES frames, no window) =="
printf '  %-18s %s\n' "source" "$FRAME_VIDEO"
printf '  %-18s %s (clip holds %s)\n' "frames requested" "$FRAMES" "$AVAILABLE_FRAMES"

set +e
# basesink debug is what reports the authoritative rendered/dropped counters.
# shellcheck disable=SC2046
GST_DEBUG=basesink:5 gst-launch-1.0 -e $(pipeline_head "$FRAME_VIDEO") \
    ! fakesink num-buffers="$FRAMES" sync=false \
    >"$WORKDIR/frames.out" 2>"$WORKDIR/frames.log"
frames_rc=$?
set -e

counters="$(grep -oE 'rendered: [0-9]+, dropped: [0-9]+' "$WORKDIR/frames.log" | tail -n1 || true)"
rendered="$(sed -n 's/^rendered: \([0-9]*\).*/\1/p' <<<"$counters")"
dropped="$(sed -n 's/.*dropped: \([0-9]*\)$/\1/p' <<<"$counters")"

printf '  %-18s %s\n' "exit status" "$frames_rc"
printf '  %-18s %s\n' "sink counters" "${counters:-<not reported>}"

if (( frames_rc == 0 )); then
    note_pass "pipeline exited cleanly on its own"
else
    tail -n 20 "$WORKDIR/frames.log" >&2
    note_fail "pipeline exited with status $frames_rc"
fi
if [[ "$rendered" == "$FRAMES" ]]; then
    note_pass "sink rendered exactly $FRAMES frames"
else
    note_fail "sink rendered '${rendered:-?}' frames, expected $FRAMES"
fi
if [[ "$dropped" == "0" ]]; then
    note_pass "no frames dropped"
else
    note_fail "sink dropped '${dropped:-?}' frames, expected 0"
fi

# --------------------------------------------------------------- CHECK 2 ---
PACE_DURATION="$(video_duration_seconds "$PACE_VIDEO")"

bold "== CHECK 2: real-time pacing =="
printf '  %-18s %s\n' "source" "$PACE_VIDEO"
printf '  %-18s %s s\n' "clip duration" "$PACE_DURATION"

timed_run() {
    # timed_run <sync> <logfile>; sets ELAPSED and RUN_RC
    local sync="$1" logfile="$2" start end
    start="$(date +%s.%N)"
    set +e
    # shellcheck disable=SC2046
    gst-launch-1.0 -e $(pipeline_head "$PACE_VIDEO") ! fakesink sync="$sync" \
        >"$logfile" 2>&1
    RUN_RC=$?
    set -e
    end="$(date +%s.%N)"
    ELAPSED="$(awk -v a="$start" -v b="$end" 'BEGIN { printf "%.2f", b - a }')"
}

timed_run true "$WORKDIR/paced.log";   paced_elapsed="$ELAPSED";   paced_rc="$RUN_RC"
timed_run false "$WORKDIR/unpaced.log"; unpaced_elapsed="$ELAPSED"; unpaced_rc="$RUN_RC"

printf '  %-18s %s s (exit %s)\n' "sync=true" "$paced_elapsed" "$paced_rc"
printf '  %-18s %s s (exit %s)\n' "sync=false" "$unpaced_elapsed" "$unpaced_rc"

if (( paced_rc == 0 && unpaced_rc == 0 )); then
    note_pass "both playback runs exited cleanly"
else
    tail -n 20 "$WORKDIR/paced.log" "$WORKDIR/unpaced.log" >&2
    note_fail "a playback run failed (sync=true: $paced_rc, sync=false: $unpaced_rc)"
fi

# Paced playback should land near the clip's real duration. The window is
# deliberately generous: startup and NVDEC teardown add a fraction of a second.
if awk -v e="$paced_elapsed" -v d="$PACE_DURATION" \
       'BEGIN { exit !(e >= 0.8 * d && e <= 1.25 * d + 2.0) }'; then
    note_pass "paced run ($paced_elapsed s) matches clip duration ($PACE_DURATION s)"
else
    note_fail "paced run ($paced_elapsed s) is not close to clip duration ($PACE_DURATION s)"
fi

# Unpaced playback proves the pacing was doing something: without a clock the
# same file is consumed far faster than real time.
if awk -v u="$unpaced_elapsed" -v d="$PACE_DURATION" \
       'BEGIN { exit !(u < 0.6 * d) }'; then
    note_pass "unpaced run ($unpaced_elapsed s) is much faster than real time"
else
    note_fail "unpaced run ($unpaced_elapsed s) was not faster than real time"
fi

# ---------------------------------------------------------------- summary ---
bold "== Summary =="
if (( FAILURES == 0 )); then
    bold "All checks passed."
    exit 0
fi
die "$FAILURES check(s) failed."
