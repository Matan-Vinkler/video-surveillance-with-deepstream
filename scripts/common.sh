#!/usr/bin/env bash
# common.sh - shared helpers for the video-input milestone.
#
# Source it from the other scripts:
#     source "$(dirname "$0")/common.sh"
# Or run its preflight checks directly:
#     ./scripts/common.sh --selftest
#
# Everything here is read-only with respect to the system: it discovers paths
# and capabilities, it never installs, modifies or deletes anything.

set -euo pipefail

# ----------------------------------------------------------------- output --
bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
info()  { printf '%s\n' "$*"; }
warn()  { printf 'WARNING: %s\n' "$*" >&2; }
die()   { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# ------------------------------------------------------ DeepStream lookup --
# On this JetPack the DeepStream SDK is NOT registered with dpkg, so the
# version cannot be queried with package tools. It is discovered from the
# filesystem instead, via the stable unversioned symlink
# (/opt/nvidia/deepstream/deepstream -> deepstream-<version>) so that no
# version number is hard-coded anywhere in this repository.
DS_LINK="${DS_LINK:-/opt/nvidia/deepstream/deepstream}"

ds_root() {
    [[ -e "$DS_LINK" ]] || die "DeepStream not found at '$DS_LINK'.
       If it is installed elsewhere, re-run with DS_LINK=/path/to/deepstream."
    readlink -f "$DS_LINK"
}

ds_version() {
    local root version_file version
    root="$(ds_root)"
    version_file="$root/version"
    [[ -r "$version_file" ]] || die "DeepStream version file not readable: '$version_file'."
    version="$(sed -n 's/^Version:[[:space:]]*\(.*\)$/\1/p' "$version_file" | head -n1)"
    [[ -n "$version" ]] || die "Could not parse a version from '$version_file'."
    printf '%s\n' "$version"
}

ds_streams_dir() {
    local dir
    dir="$(ds_root)/samples/streams"
    [[ -d "$dir" ]] || die "DeepStream sample stream directory missing: '$dir'."
    printf '%s\n' "$dir"
}

# ---------------------------------------------------------- video sources --
# Primary source: 48 s, 1080p30, H.264 High, contains many pedestrians.
# Quick source:   ~6 s, 1080p30, H.264 Main, one person running (fast checks).
DEFAULT_VIDEO_NAME="${DEFAULT_VIDEO_NAME:-sample_1080p_h264.mp4}"
QUICK_VIDEO_NAME="${QUICK_VIDEO_NAME:-sample_run.mov}"

resolve_video() {
    # resolve_video [name-or-path] -> absolute path, or a clear error
    local want="${1:-$DEFAULT_VIDEO_NAME}" candidate
    if [[ "$want" == */* ]]; then
        candidate="$want"
    else
        candidate="$(ds_streams_dir)/$want"
    fi
    [[ -e "$candidate" ]] || die "Video not found: '$candidate'.
       Available samples are in $(ds_streams_dir)"
    [[ -r "$candidate" ]] || die "Video exists but is not readable: '$candidate'."
    readlink -f "$candidate"
}

# ------------------------------------------------------------ preflight ----
REQUIRED_TOOLS=(gst-launch-1.0 gst-inspect-1.0 gst-discoverer-1.0)
REQUIRED_ELEMENTS=(filesrc qtdemux queue h264parse nvv4l2decoder fakesink)

require_tools() {
    local tool
    for tool in "${REQUIRED_TOOLS[@]}"; do
        command -v "$tool" >/dev/null 2>&1 \
            || die "Required tool '$tool' is not in PATH. Install the gstreamer1.0-tools package."
    done
}

require_elements() {
    local element missing=()
    for element in "$@"; do
        gst-inspect-1.0 "$element" >/dev/null 2>&1 || missing+=("$element")
    done
    if (( ${#missing[@]} > 0 )); then
        die "Missing GStreamer element(s): ${missing[*]}
       Check with: gst-inspect-1.0 <element>"
    fi
}

# ------------------------------------------------------------- media info --
video_duration_seconds() {
    # Duration in fractional seconds, parsed from gst-discoverer-1.0.
    local file="$1" stamp
    stamp="$(gst-discoverer-1.0 "$file" 2>/dev/null | awk '/^  Duration:/ { print $2; exit }')"
    [[ -n "$stamp" ]] || die "Could not determine the duration of '$file' with gst-discoverer-1.0."
    awk -F: '{ printf "%.3f\n", ($1 * 3600) + ($2 * 60) + $3 }' <<<"$stamp"
}

# ---------------------------------------------------------------- display --
# Overridable so the "no display available" path can be exercised on a machine
# that does in fact have one: X11_SOCKET_DIR=/nonexistent DISPLAY= ...
X11_SOCKET_DIR="${X11_SOCKET_DIR:-/tmp/.X11-unix}"

display_works() {
    local candidate="$1"
    [[ -S "$X11_SOCKET_DIR/X${candidate#:}" ]] || return 1
    if command -v xrandr >/dev/null 2>&1; then
        DISPLAY="$candidate" xrandr -q >/dev/null 2>&1
    else
        # No xrandr available: the socket's existence is all we can check.
        return 0
    fi
}

find_display() {
    # Echo the first usable X display, or return 1 if there is none.
    local candidate socket
    if [[ -n "${DISPLAY:-}" ]] && display_works "$DISPLAY"; then
        printf '%s\n' "$DISPLAY"
        return 0
    fi
    for socket in "$X11_SOCKET_DIR"/X*; do
        [[ -S "$socket" ]] || continue
        candidate=":${socket##*/X}"
        if display_works "$candidate"; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

# --------------------------------------------------------------- selftest --
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    [[ "${1:-}" == "--selftest" ]] || die "Usage: $0 --selftest"

    bold "== Tooling =="
    require_tools
    for tool in "${REQUIRED_TOOLS[@]}"; do
        printf '  %-22s %s\n' "$tool" "$(command -v "$tool")"
    done
    printf '  %-22s %s\n' "GStreamer" "$(gst-launch-1.0 --version | awk 'NR==2 { print $2 }')"

    bold "== DeepStream =="
    printf '  %-22s %s\n' "symlink" "$DS_LINK"
    printf '  %-22s %s\n' "resolved root" "$(ds_root)"
    printf '  %-22s %s\n' "version (discovered)" "$(ds_version)"
    printf '  %-22s %s\n' "streams dir" "$(ds_streams_dir)"

    bold "== Required elements =="
    require_elements "${REQUIRED_ELEMENTS[@]}"
    for element in "${REQUIRED_ELEMENTS[@]}"; do
        printf '  %-22s OK\n' "$element"
    done

    bold "== Video sources =="
    printf '  %-22s %s\n' "primary" "$(resolve_video "$DEFAULT_VIDEO_NAME")"
    printf '  %-22s %s\n' "quick"   "$(resolve_video "$QUICK_VIDEO_NAME")"

    bold "== Display =="
    if detected="$(find_display)"; then
        printf '  %-22s %s (visible playback available)\n' "usable DISPLAY" "$detected"
    else
        printf '  %-22s %s\n' "usable DISPLAY" "none (headless; use verify_simulated_stream.sh)"
    fi

    bold "Selftest passed."
fi
