#!/usr/bin/env bash
# run_simulated_stream.sh - replay a recorded video through an explicit
# GStreamer pipeline as a real-time simulated camera stream, on screen.
#
# The pipeline is written out element by element on purpose (no playbin), so
# that every stage can be explained. Pacing comes from the sink's clock
# synchronisation (sync=true): each decoded frame is held until its
# presentation timestamp arrives, which back-pressures the decoder and the
# file reader, so the file is consumed at 1x speed instead of as fast as
# possible.
#
# Usage:
#   ./scripts/run_simulated_stream.sh                 # default source, one pass
#   ./scripts/run_simulated_stream.sh --loop          # replay until Ctrl-C
#   ./scripts/run_simulated_stream.sh --passes 3      # replay exactly 3 times
#   ./scripts/run_simulated_stream.sh --crowded       # busier 48 s test source
#   ./scripts/run_simulated_stream.sh --sink fakesink # no window (loop testing)
#   ./scripts/run_simulated_stream.sh sample_run.mov  # any other sample/path

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

SINK="nv3dsink"
LOOP=0
PASSES=0
VIDEO_ARG=""

while (( $# > 0 )); do
    case "$1" in
        --crowded) VIDEO_ARG="$CROWDED_VIDEO_NAME" ;;
        --loop)    LOOP=1 ;;
        --passes)  shift; (( $# > 0 )) || die "--passes needs a value."; PASSES="$1" ;;
        --sink)    shift; (( $# > 0 )) || die "--sink needs a value."; SINK="$1" ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        -*) die "Unknown option '$1'. Try --help." ;;
        *)  VIDEO_ARG="$1" ;;
    esac
    shift
done

[[ "$PASSES" =~ ^[0-9]+$ ]] || die "--passes must be a non-negative integer, got '$PASSES'."
if (( LOOP == 1 && PASSES > 0 )); then
    die "--loop (run until Ctrl-C) and --passes N (run N times) are mutually exclusive."
fi

require_tools
require_elements "${REQUIRED_ELEMENTS[@]}" "$SINK"
VIDEO="$(resolve_video "${VIDEO_ARG:-$DEFAULT_VIDEO_NAME}")"

# A window needs somewhere to go, but a headless sink does not. Fail loudly and
# usefully rather than hanging or crashing deep inside the sink.
if sink_needs_display "$SINK"; then
    if ! DETECTED_DISPLAY="$(find_display)"; then
        die "No usable X display found, so visible playback is not possible.

       This shell has DISPLAY='${DISPLAY:-unset}'.
       If a desktop session is running on the console, point at it explicitly:
           DISPLAY=:1 $0 $*
       To exercise the same pipeline without a window:
           $0 --sink fakesink
       For the full headless check, use instead:
           ./scripts/verify_simulated_stream.sh"
    fi
    export DISPLAY="$DETECTED_DISPLAY"
    display_note="$DISPLAY"
else
    display_note="not required (headless sink '$SINK')"
fi

DURATION="$(video_duration_seconds "$VIDEO")"

if (( PASSES > 0 )); then
    mode="$PASSES pass(es)"
elif (( LOOP )); then
    mode="looping until Ctrl-C"
else
    mode="single pass"
fi

bold "== Simulated camera stream =="
printf '  %-20s %s\n' "source" "$VIDEO"
printf '  %-20s %s s per pass\n' "duration" "$DURATION"
printf '  %-20s %s\n' "display" "$display_note"
printf '  %-20s %s (sync=true -> real-time pacing)\n' "sink" "$SINK"
printf '  %-20s %s\n' "mode" "$mode"
info ""

# filesrc      : read the recording as raw bytes
# qtdemux      : split the MP4/MOV container into elementary streams
#                (the same demuxer serves .mp4 and .mov - both are ISO-BMFF)
# demux.video_0: take only the video stream (a camera has no audio track)
# queue        : thread boundary + buffering between demux and decode
# h264parse    : re-frame H.264 from avc (length-prefixed) to byte-stream
#                (Annex-B) with in-band SPS/PPS, which nvv4l2decoder requires
# nvv4l2decoder: hardware NVDEC decode -> NV12 frames in NVMM memory
# <sink>       : renders NVMM/NV12 directly and paces on the pipeline clock
build_pipeline() {
    printf '%s\n' \
        "filesrc location=$VIDEO" \
        "! qtdemux name=demux" \
        "demux.video_0" \
        "! queue" \
        "! h264parse" \
        "! nvv4l2decoder" \
        "! $SINK sync=true"
}

bold "== Pipeline =="
build_pipeline | sed 's/^/  /'
info ""

run_once() {
    # shellcheck disable=SC2046  # word splitting of the pipeline is intended
    gst-launch-1.0 -e $(build_pipeline)
}

# gst-launch -e catches SIGINT itself, turns it into EOS and exits 0. Without
# this trap a looping run would simply start the next pass, so Ctrl-C would
# never end the loop.
STOP=0
trap 'STOP=1' INT TERM

if (( LOOP == 0 && PASSES == 0 )); then
    run_once
    bold "Playback finished (clean EOS)."
    exit 0
fi

# Looping re-runs the pipeline rather than seeking inside it, so the pipeline
# itself stays the minimal explainable one shown above. The cost is a short
# gap per pass (~0.17 s on this machine) while NVDEC is torn down and
# re-initialised. Gapless looping would need a segment seek from an
# application with a bus handler, which is out of scope for this milestone.
info "Looping replays the file from the start each pass; expect a brief gap between passes."
info ""

pass=1
while (( STOP == 0 )); do
    (( PASSES == 0 || pass <= PASSES )) || break
    bold "-- pass $pass --"
    if ! run_once; then
        die "Pipeline failed on pass $pass."
    fi
    pass=$(( pass + 1 ))
done

completed=$(( pass - 1 ))
if (( STOP == 1 )); then
    bold "Stopped after $completed pass(es)."
else
    bold "Completed $completed pass(es)."
fi
