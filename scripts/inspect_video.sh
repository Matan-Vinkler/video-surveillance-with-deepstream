#!/usr/bin/env bash
# inspect_video.sh - report the container, codec, resolution, frame rate and
# duration of the recorded video used as the simulated camera source, and
# optionally dump the caps negotiated at every link of the pipeline.
#
# Usage:
#   ./scripts/inspect_video.sh                 # inspect the default source
#   ./scripts/inspect_video.sh --caps          # also show negotiated caps
#   ./scripts/inspect_video.sh sample_walk.mov # inspect another sample
#   ./scripts/inspect_video.sh /path/to/x.mp4

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

SHOW_CAPS=0
VIDEO_ARG=""

while (( $# > 0 )); do
    case "$1" in
        --caps) SHOW_CAPS=1 ;;
        -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
        -*) die "Unknown option '$1'. Try --help." ;;
        *)  VIDEO_ARG="$1" ;;
    esac
    shift
done

require_tools
VIDEO="$(resolve_video "${VIDEO_ARG:-$DEFAULT_VIDEO_NAME}")"

bold "== Source =="
printf '  %-20s %s\n' "file" "$VIDEO"
printf '  %-20s %s bytes\n' "size" "$(stat -c %s "$VIDEO")"
printf '  %-20s DeepStream %s\n' "origin" "$(ds_version)"

bold "== gst-discoverer-1.0 =="
# NvMM/"Opening in BLOCKING MODE" lines are hardware-decoder chatter on stderr;
# they are filtered for readability but the exit status is still checked.
set +e
discovery="$(gst-discoverer-1.0 "$VIDEO" 2>&1)"
discovery_rc=$?
set -e
(( discovery_rc == 0 )) || { printf '%s\n' "$discovery" >&2; die "gst-discoverer-1.0 failed (exit $discovery_rc)."; }
grep -vE 'NvMM|Opening in BLOCKING MODE|^$' <<<"$discovery"

if (( SHOW_CAPS == 1 )); then
    bold "== Caps negotiated at each link =="
    info "(20 frames decoded to a fakesink purely to observe negotiation)"
    set +e
    verbose="$(gst-launch-1.0 -v \
        filesrc "location=$VIDEO" \
        ! qtdemux name=demux \
        demux.video_0 \
        ! queue \
        ! h264parse \
        ! nvv4l2decoder \
        ! fakesink num-buffers=20 sync=false 2>&1)"
    caps_rc=$?
    set -e
    (( caps_rc == 0 )) || { printf '%s\n' "$verbose" >&2; die "Caps probe pipeline failed (exit $caps_rc)."; }
    # Lines look like:
    #   /GstPipeline:pipeline0/GstH264Parse:h264parse0.GstPad:src: caps = ...
    #   /GstPipeline:pipeline0/nvv4l2decoder:nvv4l2decoder0.GstPad:src: caps = ...
    # NVIDIA element type names are not Gst-prefixed, so strip that optionally.
    # Order is preserved (negotiation order); duplicates are collapsed.
    grep -oE '/GstPipeline:pipeline0/[^ ]+\.GstPad:(sink|src): caps = .*' <<<"$verbose" \
        | sed -E 's#^/GstPipeline:pipeline0/(Gst)?##; s#:[^.:]*\.GstPad:#.#' \
        | awk '!seen[$0]++'
fi

bold "Inspection complete."
