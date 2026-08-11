#!/usr/bin/env bash
# ds_common.sh - shared helpers for the DeepStream inference pipeline milestone.
#
# Source it from the other scripts:
#     source "$(dirname "$0")/ds_common.sh"
# Or run its preflight checks directly:
#     ./scripts/ds_common.sh --selftest
#
# Like trt_common.sh before it, this file does NOT modify the scripts belonging
# to completed milestones. It sources trt_common.sh (which sources common.sh),
# so the video-input and TensorRT milestones stay byte-identical.
#
# Read-only with respect to the system. The one thing it writes is the stable
# engine symlink inside models/engines/, described below.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/trt_common.sh"

CONFIG_DIR="${CONFIG_DIR:-$REPO_ROOT/configs}"

# Metadata dumps. deepstream-app writes these from FOUR DIFFERENT probes, at
# different points in the pipeline -- which is what makes it possible to compare
# detector output against tracker output from a single run:
#
#   DETECTION_DIR   gie-kitti-output-dir        primary-gie src pad  (pre-tracker)
#   TRACK_DIR       kitti-track-output-dir      tracker src pad      (post-tracker)
#   TERMINATED_DIR  terminated-track-output-dir tracker src pad
#   SHADOW_DIR      shadow-track-output-dir     tracker src pad
DETECTION_DIR="${DETECTION_DIR:-$REPO_ROOT/models/detections}"
TRACK_DIR="${TRACK_DIR:-$REPO_ROOT/models/tracks}"
TERMINATED_DIR="${TERMINATED_DIR:-$REPO_ROOT/models/tracks_terminated}"
SHADOW_DIR="${SHADOW_DIR:-$REPO_ROOT/models/tracks_shadow}"

# Restricted-zone evidence. NOT written by deepstream-app -- it has no probe for
# analytics metadata -- but by tools/analytics_probe.cpp. See
# docs/milestone-05-restricted-zone.md
ZONE_DIR="${ZONE_DIR:-$REPO_ROOT/models/zone}"

# Milestone 7. The Triton model repository: its config.pbtxt is committed
# application configuration, while 1/model.plan is the Milestone 4 engine,
# bind-mounted read-only at run time and never copied or committed.
TRITON_REPO_DIR="${TRITON_REPO_DIR:-$REPO_ROOT/models/triton_model_repo}"
TRITON_MODEL_NAME="${TRITON_MODEL_NAME:-trafficcamnet}"
PROBE_BIN="${PROBE_BIN:-$REPO_ROOT/build/analytics_probe}"

# The committed nvinfer config references a version-free engine name, so that no
# TensorRT version or GPU name is hard-coded in a checked-in file. The wrapper
# maintains this symlink and points it at whatever engine the CURRENT
# environment expects. If that engine is absent the run fails loudly: this
# milestone never builds an engine.
STABLE_ENGINE_NAME="${STABLE_ENGINE_NAME:-trafficcamnet_fp16.engine}"
STABLE_ENGINE="$ENGINE_DIR/$STABLE_ENGINE_NAME"

require_deepstream_app() {
    command -v deepstream-app >/dev/null 2>&1 \
        || die "'deepstream-app' is not in PATH.
       It ships with DeepStream, normally at $(ds_root)/bin/deepstream-app."
}

# --------------------------------------------------------------- tracker ----
# Checkpoint 2 uses NVIDIA's tracker exactly as installed: one shared low-level
# library, and a vendor YAML that selects NvSORT. Neither is copied into this
# repository and neither is modified -- so both are discovered through the
# unversioned DeepStream symlink and checked before any pipeline is started.
# A missing asset must fail here with a readable message, not deep inside the
# low-level library at runtime.
tracker_lib() { printf '%s\n' "$(ds_root)/lib/libnvds_nvmultiobjecttracker.so"; }
tracker_config() {
    printf '%s\n' "$(ds_root)/samples/configs/deepstream-app/config_tracker_NvSORT.yml"
}

require_tracker_assets() {
    # `die` inside $( ) only ends the subshell, and callers may invoke this with
    # `set -e` suspended -- so each lookup is guarded explicitly. This is the
    # same trap that bit model_contract() in Milestone 4.
    local lib cfg
    lib="$(tracker_lib)" || return 1
    cfg="$(tracker_config)" || return 1
    [[ -n "$lib" && -n "$cfg" ]] \
        || die "DeepStream could not be located, so the tracker assets cannot be checked."
    [[ -r "$lib" ]] || die "The DeepStream low-level tracker library is missing or unreadable:
           $lib

       DeepStream 9.x ships one tracker library for every backend; without it
       no tracker can be instantiated at all. Nothing in this repository builds
       or installs it."
    [[ -r "$cfg" ]] || die "NVIDIA's NvSORT tracker configuration is missing or unreadable:
           $cfg

       This milestone uses the vendor YAML as shipped and never copies or
       modifies it. Present in that directory:
$(ls -1 "$(dirname "$cfg")"/config_tracker_*.yml 2>/dev/null | sed 's|^|           |' || echo '           (none)')"
}

# ------------------------------------------------------------- analytics ----
# The restricted zone is the one piece of configuration in this repository that
# is genuinely OUR application logic, so unlike the tracker YAML it is a
# repository-local file rather than a vendor one.
analytics_config() {
    printf '%s\n' "$CONFIG_DIR/config_nvdsanalytics_restricted_zone.txt"
}

require_analytics_config() {
    local cfg
    cfg="$(analytics_config)"
    [[ -r "$cfg" ]] || die "The restricted-zone analytics configuration is missing:
           $cfg"
}

require_probe() {
    # deepstream-app cannot report nvdsanalytics metadata, so the verification
    # needs its own reader. Build it on demand rather than committing a binary.
    [[ -x "$PROBE_BIN" ]] && return 0
    printf 'Building the analytics probe (%s)...\n' "$PROBE_BIN"
    make -C "$REPO_ROOT/tools" >/dev/null \
        || die "Could not build the analytics probe. Try: make -C tools"
    [[ -x "$PROBE_BIN" ]] \
        || die "'make -C tools' reported success but '$PROBE_BIN' is not executable."
}

require_triton_repo() {
    local cfg="$TRITON_REPO_DIR/$TRITON_MODEL_NAME/config.pbtxt"
    [[ -r "$cfg" ]] || die "The Triton model repository entry is missing:
           $cfg"
    [[ -d "$TRITON_REPO_DIR/$TRITON_MODEL_NAME/1" ]] \
        || die "The Triton model version directory is missing:
           $TRITON_REPO_DIR/$TRITON_MODEL_NAME/1
       It must exist so the engine can be mounted onto 1/model.plan."

    # The engine is bind-mounted onto 1/model.plan, INSIDE a model repository
    # that is itself mounted read-only. Docker mounts parent before child, so by
    # the time runc mounts the file the parent is already read-only and it cannot
    # create the mountpoint:
    #
    #   error mounting "...engine" to rootfs at ".../1/model.plan": create
    #   mountpoint for .../model.plan mount: read-only file system
    #
    # A zero-byte placeholder makes the mountpoint exist in the SOURCE tree, so
    # runc only has to mount over it. The engine is never copied and the repo
    # mount stays read-only. .gitignore excludes this path, so the placeholder is
    # never committed and never masks a real engine.
    local plan="$TRITON_REPO_DIR/$TRITON_MODEL_NAME/1/model.plan"
    if [[ ! -e "$plan" ]]; then
        : >"$plan" || die "Could not create the mountpoint placeholder: $plan"
    elif [[ -s "$plan" ]]; then
        die "'$plan' is a NON-EMPTY real file.
       It should only ever be a zero-byte mountpoint placeholder; the engine is
       bind-mounted over it at run time and never copied here. Refusing to
       continue, because a real plan file here would silently be the model
       Triton loads. Move it aside and re-run."
    fi
}

expected_fp16_engine() {
    # The exact engine filename the current environment implies, derived the
    # same way build_engines.sh derived it: model dims from the ONNX contract,
    # TensorRT version and GPU discovered at run time.
    local contract w h
    contract="$(mktemp)"
    if ! model_contract >"$contract"; then
        rm -f "$contract"
        die "TensorRT could not parse the ONNX model; cannot determine the expected engine name."
    fi
    w="$(contract_field "$contract" input_w)"
    h="$(contract_field "$contract" input_h)"
    rm -f "$contract"
    engine_path fp16 "$w" "$h"
}

ensure_engine_link() {
    # Point the stable name at the versioned engine, or fail with instructions.
    # Never builds anything.
    local target current
    target="$(expected_fp16_engine)"

    if [[ ! -s "$target" ]]; then
        die "The FP16 engine this environment expects is missing:
           $target

       This milestone does not build engines. Build it first with the
       Milestone 4 script, which is unchanged:

           ./scripts/build_engines.sh --precision fp16

       Present in $ENGINE_DIR:
$(ls -1 "$ENGINE_DIR"/*.engine 2>/dev/null | sed 's|^|           |' || echo '           (none)')"
    fi

    if [[ -L "$STABLE_ENGINE" ]]; then
        current="$(readlink -f "$STABLE_ENGINE" || true)"
        [[ "$current" == "$(readlink -f "$target")" ]] || ln -sfn "$(basename "$target")" "$STABLE_ENGINE"
    elif [[ -e "$STABLE_ENGINE" ]]; then
        die "'$STABLE_ENGINE' exists but is not a symlink.
       Refusing to replace a real file. Move it aside and re-run."
    else
        ln -s "$(basename "$target")" "$STABLE_ENGINE"
    fi

    [[ -s "$STABLE_ENGINE" ]] \
        || die "Stable engine link '$STABLE_ENGINE' does not resolve to a readable engine."
    printf '%s\n' "$target"
}

engine_fingerprint() {
    # Used to prove the engine was not rebuilt or modified by a run.
    local resolved
    resolved="$(readlink -f "$STABLE_ENGINE")"
    printf '%s  %s  %s\n' \
        "$(sha256sum "$resolved" | cut -d' ' -f1)" \
        "$(stat -c %Y "$resolved")" \
        "$(stat -c %s "$resolved")"
}

require_config() {
    local path="$CONFIG_DIR/$1"
    [[ -r "$path" ]] || die "Configuration file not found: '$path'."
    printf '%s\n' "$path"
}

# --------------------------------------------------------------- selftest ----
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    [[ "${1:-}" == "--selftest" ]] || die "Usage: $0 --selftest"

    bold "== DeepStream application =="
    require_deepstream_app
    printf '  %-24s %s\n' "deepstream-app" "$(command -v deepstream-app)"
    printf '  %-24s %s\n' "DeepStream" "$(ds_version)"

    bold "== Required elements =="
    require_elements nvstreammux nvinfer nvtracker nvdsanalytics \
                     nvmultistreamtiler nvvideoconvert nvdsosd nv3dsink fakesink
    printf '  %-24s %s\n' "pipeline elements" "all present"

    bold "== Tracker assets (vendor, read-only) =="
    require_tracker_assets
    printf '  %-24s %s\n' "low-level library" "$(tracker_lib)"
    printf '  %-24s %s\n' "NvSORT config" "$(tracker_config)"

    bold "== Restricted zone (ours) =="
    require_analytics_config
    printf '  %-24s %s\n' "analytics config" "$(analytics_config)"
    printf '  %-24s %s\n' "ROI" "$(sed -n 's/^roi-RF=//p' "$(analytics_config)")"
    printf '  %-24s %s\n' "class filter" "class-id=$(sed -n 's/^class-id=//p' "$(analytics_config)")"

    bold "== Engine =="
    resolved="$(ensure_engine_link)"
    printf '  %-24s %s\n' "expected (discovered)" "$(basename "$resolved")"
    printf '  %-24s %s -> %s\n' "stable link" "$STABLE_ENGINE_NAME" "$(readlink "$STABLE_ENGINE")"
    printf '  %-24s %s bytes\n' "size" "$(stat -c %s "$(readlink -f "$STABLE_ENGINE")")"

    bold "== Configuration =="
    for cfg in config_infer_primary_trafficcamnet.txt \
               config_nvdsanalytics_restricted_zone.txt \
               deepstream_app_walk_headless.txt \
               deepstream_app_walk_display.txt; do
        printf '  %-24s %s\n' "$cfg" "$([[ -r "$CONFIG_DIR/$cfg" ]] && echo OK || echo MISSING)"
    done

    bold "== Source =="
    printf '  %-24s %s\n' "video" "$(resolve_video)"
    printf '  %-24s %s\n' "labels" "$(model_labels)"

    bold "Selftest passed."
fi
