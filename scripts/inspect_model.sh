#!/usr/bin/env bash
# inspect_model.sh - report the input/output contract of the TrafficCamNet ONNX
# model, the operators TensorRT resolves it to, and whether the shipped INT8
# calibration cache covers every tensor that an INT8 build would need.
#
# This PARSES the model with TensorRT's own ONNX parser. It never builds an
# engine: build_serialized_network() is not called and no file is written.
#
# Usage:
#   ./scripts/inspect_model.sh              # human-readable report
#   ./scripts/inspect_model.sh --raw        # tab-separated records, for scripts

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/trt_common.sh"

RAW=0
while (( $# > 0 )); do
    case "$1" in
        --raw) RAW=1 ;;
        -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
        *) die "Unknown option '$1'. Try --help." ;;
    esac
    shift
done

require_tools
require_trtexec

REPORT="$(mktemp)"
trap 'rm -f "$REPORT"' EXIT

# A parser failure must surface as a failure, not as an empty report.
if ! model_contract >"$REPORT"; then
    printf '%s\n' "$(cat "$REPORT")" >&2
    die "TensorRT could not parse '$(model_onnx)'. See the parser errors above."
fi

if (( RAW == 1 )); then
    cat "$REPORT"
    exit 0
fi

ONNX="$(model_onnx)"
CALIB="$(model_calib)"

bold "== Source =="
printf '  %-22s %s\n' "onnx" "$ONNX"
printf '  %-22s %s bytes\n' "size" "$(stat -c %s "$ONNX")"
printf '  %-22s %s\n' "sha256" "$(sha256sum "$ONNX" | cut -c1-16)…"
printf '  %-22s DeepStream %s\n' "origin" "$(ds_version)"
printf '  %-22s %s\n' "labels" "$(tr '\n' ' ' < "$(model_labels)")"

bold "== Parse (TensorRT $(trt_version) ONNX parser) =="
printf '  %-22s %s\n' "parse succeeded" "$(contract_field "$REPORT" parse_ok)"
printf '  %-22s %s\n' "parser errors" "$(contract_field "$REPORT" parse_errors)"
printf '  %-22s %s\n' "network layers" "$(contract_field "$REPORT" num_layers)"

bold "== Input =="
printf '  %-22s %s\n' "name" "$(contract_field "$REPORT" input_name)"
printf '  %-22s %s\n' "dims (NCHW)" "$(contract_field "$REPORT" input_dims)"
printf '  %-22s %s\n' "dtype" "$(contract_field "$REPORT" input_dtype)"
if [[ "$(contract_field "$REPORT" input_dynamic_batch)" == "1" ]]; then
    printf '  %-22s %s\n' "batch dimension" "dynamic (-1) -> an optimisation profile is required"
else
    printf '  %-22s %s\n' "batch dimension" "static"
fi

bold "== Outputs =="
awk -F'\t' '$1 == "output" { printf "  %-24s %-18s %s\n", $2, $3, $4 }' "$REPORT"

bold "== Layer types resolved by TensorRT =="
awk -F'\t' '$1 == "layertype" { printf "  %-22s %s\n", $2, $3 }' "$REPORT"

bold "== INT8 calibration cache =="
CALIB_MISSING="$(contract_field "$REPORT" calib_missing)"
printf '  %-22s %s\n' "file" "$CALIB"
printf '  %-22s %s\n' "header" "$(contract_field "$REPORT" calib_header)"
printf '  %-22s %s\n' "entries in cache" "$(contract_field "$REPORT" calib_entries)"
printf '  %-22s %s\n' "tensors needing scale" "$(contract_field "$REPORT" calib_required)"
printf '  %-22s %s\n' "unused cache entries" "$(contract_field "$REPORT" calib_unused)"
printf '  %-22s %s\n' "MISSING scales" "$CALIB_MISSING"

if [[ "$CALIB_MISSING" == "0" ]]; then
    info "  -> every tensor an INT8 build needs has a scale in the cache."
    info "     Note: the cache header records the TensorRT version that wrote it."
    info "     Whether this runtime accepts it is an empirical question, answered"
    info "     only by an actual INT8 build."
else
    warn "Tensors without a calibration scale (an INT8 build would fail):"
    awk -F'\t' '$1 == "calib_missing_tensor" { print "       " $2 }' "$REPORT" >&2
fi

bold "Inspection complete."
