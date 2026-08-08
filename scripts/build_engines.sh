#!/usr/bin/env bash
# build_engines.sh - build TensorRT engines from the TrafficCamNet ONNX model.
#
# Building and benchmarking are deliberately SEPARATE operations. This script
# only builds and verifies artifacts; it never measures inference performance
# (--skipInference), so no builder work can perturb a benchmark timing.
#
# Three configurations, chosen for different purposes:
#
#   fp32  --noTF32                      A genuine controlled FP32 baseline.
#                                       Without --noTF32, TensorRT enables TF32
#                                       on Ampere and "FP32" would silently mean
#                                       10-bit mantissa.
#   fp16  --fp16                        Deployment engine. TF32 is left enabled,
#                                       so layers the builder does not place in
#                                       FP16 fall back the way a real deployment
#                                       would.
#   int8  --int8 --fp16 --calib=<cache> Deployment engine. INT8 where TensorRT
#                                       selects it, FP16 available as fallback,
#                                       using NVIDIA's shipped calibration cache.
#
# Note that --fp16 and --int8 mean "allow", not "force": the builder chooses per
# layer by measured timing. --profilingVerbosity=detailed plus --exportLayerInfo
# is what lets us state which precisions were actually selected, rather than
# which were requested.
#
# Usage:
#   ./scripts/build_engines.sh --precision fp32
#   ./scripts/build_engines.sh --precision all
#   ./scripts/build_engines.sh --precision int8 --force   # overwrite existing

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/trt_common.sh"

PRECISIONS=""
FORCE=0
WORKSPACE_MB="${WORKSPACE_MB:-2048}"

while (( $# > 0 )); do
    case "$1" in
        --precision) shift; (( $# > 0 )) || die "--precision needs a value."; PRECISIONS="$1" ;;
        --force)     FORCE=1 ;;
        -h|--help)   sed -n '2,36p' "$0"; exit 0 ;;
        *) die "Unknown option '$1'. Try --help." ;;
    esac
    shift
done

[[ -n "$PRECISIONS" ]] || die "--precision is required (fp32, fp16, int8 or all)."
case "$PRECISIONS" in
    all)              PRECISION_LIST=(fp32 fp16 int8) ;;
    fp32|fp16|int8)   PRECISION_LIST=("$PRECISIONS") ;;
    *) die "Unknown precision '$PRECISIONS'. Use fp32, fp16, int8 or all." ;;
esac

require_tools
require_trtexec
[[ -d "$ENGINE_DIR" ]] || die "Engine directory '$ENGINE_DIR' does not exist."
[[ -w "$ENGINE_DIR" ]] || die "Engine directory '$ENGINE_DIR' is not writable."

# ---- model contract: discover the shape rather than hard-coding it ----------
CONTRACT="$(mktemp)"
trap 'rm -f "$CONTRACT"' EXIT
model_contract >"$CONTRACT" || die "TensorRT could not parse the ONNX model; see scripts/inspect_model.sh."

INPUT_NAME="$(contract_field "$CONTRACT" input_name)"
INPUT_C="$(contract_field "$CONTRACT" input_c)"
INPUT_H="$(contract_field "$CONTRACT" input_h)"
INPUT_W="$(contract_field "$CONTRACT" input_w)"
ONNX="$(model_onnx)"
CALIB="$(model_calib)"

# The input is named "input_1:0" and trtexec shape specs are themselves
# colon-delimited, so the name must be wrapped in literal single quotes.
SHAPE_SPEC="'${INPUT_NAME}':${ENGINE_BATCH}x${INPUT_C}x${INPUT_H}x${INPUT_W}"

bold "== Build configuration =="
printf '  %-24s %s\n' "onnx" "$ONNX"
printf '  %-24s %s\n' "TensorRT" "$(trt_version)"
printf '  %-24s %s\n' "GPU" "$(gpu_slug)"
printf '  %-24s %s\n' "power mode" "$(power_mode)"
printf '  %-24s %s\n' "shape spec" "$SHAPE_SPEC"
printf '  %-24s %s MiB\n' "workspace ceiling" "$WORKSPACE_MB"
printf '  %-24s %s\n' "precisions" "${PRECISION_LIST[*]}"
info ""

precision_args() {
    # Deliberately asymmetric: see the header comment. fp32 is a controlled
    # experiment, fp16 and int8 are deployment configurations.
    case "$1" in
        fp32) printf '%s\n' "--noTF32" ;;
        fp16) printf '%s\n' "--fp16" ;;
        int8) printf '%s\n' "--int8" "--fp16" "--calib=$CALIB" ;;
        *)    die "Unhandled precision '$1'." ;;
    esac
}

FAILURES=0

for precision in "${PRECISION_LIST[@]}"; do
    engine="$(engine_path "$precision" "$INPUT_W" "$INPUT_H")"
    base="${engine%.engine}"
    build_log="${base}.build.log"
    layer_json="${base}.layers.json"

    bold "== Building $precision =="

    if [[ -e "$engine" && $FORCE -eq 0 ]]; then
        die "Engine already exists: '$engine'.
       Re-run with --force to rebuild it, or delete it first.
       Refusing to overwrite silently so that a benchmark cannot be run against
       an engine built by a different command than the one recorded here."
    fi

    mapfile -t prec_args < <(precision_args "$precision")

    # Assembled explicitly so the exact command is recorded in the log.
    cmd=(
        trtexec
        "--onnx=$ONNX"
        "--saveEngine=$engine"
        "--minShapes=$SHAPE_SPEC"
        "--optShapes=$SHAPE_SPEC"
        "--maxShapes=$SHAPE_SPEC"
        "${prec_args[@]}"
        "--memPoolSize=workspace:$WORKSPACE_MB"
        --builderOptimizationLevel=3
        --skipInference
        --profilingVerbosity=detailed
        "--exportLayerInfo=$layer_json"
        --verbose
    )

    printf '  %-24s %s C\n' "tj before" "$(tj_temp_c)"
    printf '  %s\n' "  command:"
    printf '    %s\n' "${cmd[*]}"

    { printf '# command: %s\n' "${cmd[*]}"; printf '# started: %s\n' "$(date -Is)"; } >"$build_log"

    start="$(date +%s.%N)"
    rc=0
    "${cmd[@]}" >>"$build_log" 2>&1 || rc=$?
    end="$(date +%s.%N)"
    elapsed="$(awk -v a="$start" -v b="$end" 'BEGIN { printf "%.2f", b - a }')"

    warnings="$(grep -cE '^\[[0-9/: ]+\] \[W\]|\[W\] ' "$build_log" || true)"
    errors="$(grep -cE '^\[[0-9/: ]+\] \[E\]|\[E\] ' "$build_log" || true)"

    printf '  %-24s %s\n' "exit status" "$rc"
    printf '  %-24s %s s\n' "build time" "$elapsed"
    printf '  %-24s %s\n' "warnings in log" "$warnings"
    printf '  %-24s %s\n' "errors in log" "$errors"
    printf '  %-24s %s C\n' "tj after" "$(tj_temp_c)"

    if (( rc != 0 )); then
        printf '\n  --- last 25 log lines ---\n' >&2
        tail -n 25 "$build_log" >&2
        printf '  FAIL  %s build failed (exit %s). Full log: %s\n' "$precision" "$rc" "$build_log"
        FAILURES=$(( FAILURES + 1 ))
        continue
    fi

    # ---- verify the artifact before declaring success ----------------------
    if [[ ! -s "$engine" ]]; then
        printf '  FAIL  %s reported success but produced no engine at %s\n' "$precision" "$engine"
        FAILURES=$(( FAILURES + 1 ))
        continue
    fi
    if ! python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$layer_json" 2>/dev/null; then
        printf '  FAIL  %s layer-info JSON missing or unparseable: %s\n' "$precision" "$layer_json"
        FAILURES=$(( FAILURES + 1 ))
        continue
    fi

    printf '  %-24s %s bytes\n' "engine size" "$(stat -c %s "$engine")"
    printf '  PASS  %s engine built and verified\n' "$precision"
    printf '  %-24s %s\n' "engine" "$engine"
    info ""
done

bold "== Summary =="
if (( FAILURES == 0 )); then
    bold "All requested engines built and verified."
    exit 0
fi
die "$FAILURES build(s) failed. Nothing was worked around; see the logs above."
