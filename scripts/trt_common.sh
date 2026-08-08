#!/usr/bin/env bash
# trt_common.sh - shared helpers for the TensorRT optimisation milestone.
#
# Source it from the other scripts:
#     source "$(dirname "$0")/trt_common.sh"
# Or run its preflight checks directly:
#     ./scripts/trt_common.sh --selftest
#
# This file deliberately does NOT modify common.sh, which belongs to the
# completed video-input milestone. It sources it instead, so that milestone's
# scripts and verification stay byte-identical.
#
# Everything here is read-only with respect to the system: it discovers paths,
# versions and capabilities. It never installs, modifies or deletes anything,
# and it never changes the power mode or the clocks.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE_DIR="${ENGINE_DIR:-$REPO_ROOT/models/engines}"

# ------------------------------------------------------------ model assets --
# Read from the DeepStream install path, never copied into the repository.
# The directory is root-owned, so nothing here is writable without sudo.
MODEL_SUBDIR="${MODEL_SUBDIR:-samples/models/Primary_Detector}"
ONNX_NAME="${ONNX_NAME:-resnet18_trafficcamnet_pruned.onnx}"
CALIB_NAME="${CALIB_NAME:-cal_trt.bin}"
LABELS_NAME="${LABELS_NAME:-labels.txt}"

model_dir()    { printf '%s\n' "$(ds_root)/$MODEL_SUBDIR"; }
model_onnx()   { _require_readable "$(model_dir)/$ONNX_NAME"   "ONNX model"; }
model_calib()  { _require_readable "$(model_dir)/$CALIB_NAME"  "INT8 calibration cache"; }
model_labels() { _require_readable "$(model_dir)/$LABELS_NAME" "label file"; }

_require_readable() {
    local path="$1" what="$2"
    [[ -r "$path" ]] || die "$what not readable: '$path'.
       Expected it under $(model_dir)."
    printf '%s\n' "$path"
}

# ---------------------------------------------------------- TensorRT tools --
require_trtexec() {
    command -v trtexec >/dev/null 2>&1 \
        || die "'trtexec' is not in PATH.
       It ships with TensorRT, normally at /usr/src/tensorrt/bin/trtexec."
}

trt_version() {
    # Discovered, never hard-coded. Prefer the Python binding, which reports a
    # full version string; fall back to parsing the trtexec banner.
    local v
    if v="$(python3 -c 'import tensorrt; print(tensorrt.__version__)' 2>/dev/null)" \
       && [[ -n "$v" ]]; then
        awk -F. '{ printf "%s.%s.%s\n", $1, $2, $3 }' <<<"$v"
        return 0
    fi
    # Banner looks like: &&&& RUNNING TensorRT.trtexec [TensorRT v101602] [b10]
    v="$(trtexec --help 2>&1 | sed -n 's/.*\[TensorRT v\([0-9]\{5,\}\)\].*/\1/p' | head -n1)"
    [[ -n "$v" ]] || die "Could not determine the TensorRT version from python3 or trtexec."
    # 101602 -> 10.16.2 : last two digits patch, previous two minor, rest major.
    awk -v s="$v" 'BEGIN {
        n = length(s)
        printf "%d.%d.%d\n", substr(s, 1, n - 4), substr(s, n - 3, 2), substr(s, n - 1, 2)
    }'
}

gpu_slug() {
    # "NVIDIA Jetson Orin Nano Engineering Reference ..." -> "orin-nano"
    local model slug
    model="$(tr -d '\0' < /proc/device-tree/model 2>/dev/null)" || model=""
    slug="$(sed -n 's/.*Jetson \([A-Za-z][A-Za-z]*\) \([A-Za-z][A-Za-z]*\).*/\1-\2/p' <<<"$model" \
            | tr '[:upper:]' '[:lower:]')"
    printf '%s\n' "${slug:-unknown-gpu}"
}

# ------------------------------------------------------------ model contract --
# One TensorRT ONNX parse, emitted as tab-separated records so callers can read
# fields without re-parsing. This PARSES ONLY: it never calls
# build_serialized_network(), so no engine is produced.
model_contract() {
    # `die` inside $( ) only exits the subshell, and callers invoke this under
    # `|| die`, which suspends `set -e` for everything in here. So resolution
    # failures are checked explicitly rather than relied on to abort.
    local onnx calib
    onnx="$(model_onnx)"   || return 1
    calib="$(model_calib)" || return 1
    [[ -n "$onnx" && -n "$calib" ]] || {
        printf 'ERROR: model assets could not be resolved.\n' >&2
        return 1
    }
    ONNX_PATH="$onnx" CALIB_PATH="$calib" python3 - <<'PY'
import os, sys
import tensorrt as trt

onnx_path  = os.environ["ONNX_PATH"]
calib_path = os.environ["CALIB_PATH"]
out = sys.stdout.write

logger  = trt.Logger(trt.Logger.ERROR)
builder = trt.Builder(logger)
network = builder.create_network(0)
parser  = trt.OnnxParser(network, logger)

ok = parser.parse(open(onnx_path, "rb").read())
out(f"parse_ok\t{int(bool(ok))}\n")
out(f"parse_errors\t{parser.num_errors}\n")
for i in range(parser.num_errors):
    out(f"parse_error\t{parser.get_error(i)}\n")
if not ok:
    sys.exit(1)

t = network.get_input(0)
dims = tuple(t.shape)
out(f"input_name\t{t.name}\n")
out(f"input_dims\t{','.join(str(d) for d in dims)}\n")
out(f"input_dtype\t{str(t.dtype).replace('DataType.','')}\n")
out(f"input_c\t{dims[1]}\n")
out(f"input_h\t{dims[2]}\n")
out(f"input_w\t{dims[3]}\n")
out(f"input_dynamic_batch\t{int(dims[0] == -1)}\n")

for i in range(network.num_outputs):
    o = network.get_output(i)
    shape = ",".join(str(d) for d in tuple(o.shape))
    out(f"output\t{o.name}\t{shape}\t{str(o.dtype).replace('DataType.','')}\n")

out(f"num_layers\t{network.num_layers}\n")
from collections import Counter
counts = Counter(str(network.get_layer(i).type).replace("LayerType.", "")
                 for i in range(network.num_layers))
for name, n in counts.most_common():
    out(f"layertype\t{name}\t{n}\n")

# Which activation tensors would need an INT8 dynamic range, and whether the
# shipped calibration cache actually covers them.
needed = {network.get_input(i).name for i in range(network.num_inputs)}
for i in range(network.num_layers):
    layer = network.get_layer(i)
    if layer.type == trt.LayerType.CONSTANT:   # weights carry no activation scale
        continue
    for j in range(layer.num_outputs):
        needed.add(layer.get_output(j).name)

lines  = [l for l in open(calib_path).read().splitlines() if l.strip()]
header = lines[0] if lines else ""
cached = {l.rsplit(":", 1)[0].strip() for l in lines[1:] if ":" in l}
missing = sorted(needed - cached)

out(f"calib_header\t{header}\n")
out(f"calib_entries\t{len(cached)}\n")
out(f"calib_required\t{len(needed)}\n")
out(f"calib_missing\t{len(missing)}\n")
out(f"calib_unused\t{len(cached - needed)}\n")
for name in missing:
    out(f"calib_missing_tensor\t{name}\n")
PY
}

contract_field() {
    # contract_field <report-file> <key> -> the value column of the first match
    local file="$1" key="$2" value
    value="$(awk -F'\t' -v k="$key" '$1 == k { print $2; exit }' "$file")"
    [[ -n "$value" ]] || die "Model contract report is missing the '$key' field."
    printf '%s\n' "$value"
}

# ------------------------------------------------------------ engine naming --
# Every component that invalidates an engine appears in its filename: batch,
# input resolution, precision, TensorRT version and GPU. See models/README.md.
MODEL_SLUG="${MODEL_SLUG:-trafficcamnet}"
ENGINE_BATCH="${ENGINE_BATCH:-1}"

engine_name() {
    # engine_name <precision> <width> <height>
    printf '%s_b%s_%sx%s_%s_trt%s_%s.engine\n' \
        "$MODEL_SLUG" "$ENGINE_BATCH" "$2" "$3" "$1" "$(trt_version)" "$(gpu_slug)"
}

engine_path() { printf '%s/%s\n' "$ENGINE_DIR" "$(engine_name "$@")"; }

# ------------------------------------------------------------- system state --
tegrastats_sample() {
    # tegrastats_sample <seconds> <outfile>
    # tegrastats runs until killed, so `timeout` ending it is the expected exit,
    # not a hidden failure. Success is judged by the log actually having content.
    local seconds="$1" outfile="$2" rc=0
    timeout "$seconds" tegrastats --interval 1000 --logfile "$outfile" >/dev/null 2>&1 || rc=$?
    if (( rc != 0 && rc != 124 && rc != 143 )); then
        die "tegrastats failed with exit status $rc."
    fi
    [[ -s "$outfile" ]] || die "tegrastats produced no output in ${seconds}s ('$outfile' is empty)."
}

gpu_busy_percent() {
    # Highest GR3D_FREQ (GPU load) seen in a short tegrastats sample.
    local tmp max
    tmp="$(mktemp)"
    tegrastats_sample 4 "$tmp"
    max="$(grep -oE 'GR3D_FREQ [0-9]+%' "$tmp" | grep -oE '[0-9]+' | sort -n | tail -n1)"
    rm -f "$tmp"
    printf '%s\n' "${max:-0}"
}

power_mode() { nvpmodel -q 2>/dev/null | awk '/NV Power Mode/ { print $NF; exit }'; }

tj_temp_c() {
    local zone type
    for zone in /sys/devices/virtual/thermal/thermal_zone*/; do
        type="$(cat "$zone/type" 2>/dev/null)" || continue
        if [[ "$type" == "tj-thermal" ]]; then
            awk '{ printf "%.1f\n", $1 / 1000 }' "$zone/temp"
            return 0
        fi
    done
    printf 'unknown\n'
}

gpu_cur_freq_mhz() {
    local f
    for f in /sys/devices/platform/bus@0/*.gpu/devfreq/*/cur_freq; do
        [[ -r "$f" ]] || continue
        awk '{ printf "%d\n", $1 / 1000000 }' "$f"
        return 0
    done
    printf 'unknown\n'
}

disk_free_gb() { df -BG --output=avail "$REPO_ROOT" | awk 'NR == 2 { gsub(/G/, ""); print $1 }'; }

# --------------------------------------------------------------- selftest ----
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    [[ "${1:-}" == "--selftest" ]] || die "Usage: $0 --selftest"

    bold "== TensorRT toolchain =="
    require_trtexec
    printf '  %-24s %s\n' "trtexec" "$(command -v trtexec)"
    printf '  %-24s %s\n' "TensorRT (discovered)" "$(trt_version)"
    printf '  %-24s %s\n' "CUDA" "$(nvcc --version 2>/dev/null | awk '/release/ { print $6 }' | tr -d ',V')"

    bold "== Model assets =="
    printf '  %-24s %s\n' "model dir" "$(model_dir)"
    printf '  %-24s %s\n' "onnx" "$(basename "$(model_onnx)")"
    printf '  %-24s %s\n' "calibration cache" "$(basename "$(model_calib)")"
    printf '  %-24s %s\n' "labels" "$(basename "$(model_labels)")"
    if [[ -w "$(model_dir)" ]]; then
        printf '  %-24s %s\n' "model dir writable" "yes"
    else
        printf '  %-24s %s\n' "model dir writable" "no (root-owned; engines go to models/engines/)"
    fi

    bold "== Output location =="
    printf '  %-24s %s\n' "engine dir" "$ENGINE_DIR"
    [[ -d "$ENGINE_DIR" ]] || die "Engine directory '$ENGINE_DIR' does not exist."
    [[ -w "$ENGINE_DIR" ]] || die "Engine directory '$ENGINE_DIR' is not writable."
    printf '  %-24s %s GB\n' "disk free" "$(disk_free_gb)"

    bold "== Target state (read-only; nothing is changed) =="
    printf '  %-24s %s\n' "GPU" "$(gpu_slug)"
    printf '  %-24s %s\n' "power mode" "$(power_mode)"
    printf '  %-24s %s MHz\n' "GPU clock (now)" "$(gpu_cur_freq_mhz)"
    printf '  %-24s %s C\n' "tj temperature" "$(tj_temp_c)"
    printf '  %-24s %s%%\n' "GPU busy (4s peak)" "$(gpu_busy_percent)"

    bold "== Example engine names =="
    for precision in fp32 fp16 int8; do
        printf '  %-24s %s\n' "$precision" "$(engine_name "$precision" 960 544)"
    done

    bold "Selftest passed."
fi
