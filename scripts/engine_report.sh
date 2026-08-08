#!/usr/bin/env bash
# engine_report.sh - report what a built TensorRT engine ACTUALLY is, rather
# than what was requested at build time.
#
# --fp16 and --int8 mean "allow", not "force": TensorRT chooses a precision per
# layer by measured timing. So an engine built with --fp16 may still run layers
# in FP32. This script reads the --exportLayerInfo JSON (which requires
# --profilingVerbosity=detailed) and reports the datatypes actually selected.
#
# Caveat it cannot resolve: TF32 is a compute mode for FP32 tensors, not a
# distinct datatype, so a TF32 layer is indistinguishable from FP32 here. The
# only evidence for TF32 being off is the --noTF32 build flag itself.
#
# Usage:
#   ./scripts/engine_report.sh                 # every engine in models/engines
#   ./scripts/engine_report.sh <engine-path>   # one specific engine

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/trt_common.sh"

TARGETS=()
while (( $# > 0 )); do
    case "$1" in
        -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
        -*) die "Unknown option '$1'. Try --help." ;;
        *)  TARGETS+=("$1") ;;
    esac
    shift
done

if (( ${#TARGETS[@]} == 0 )); then
    shopt -s nullglob
    TARGETS=("$ENGINE_DIR"/*.engine)
    shopt -u nullglob
fi
(( ${#TARGETS[@]} > 0 )) || die "No engines found in '$ENGINE_DIR'. Build some with scripts/build_engines.sh."

for engine in "${TARGETS[@]}"; do
    [[ -s "$engine" ]] || die "Engine missing or empty: '$engine'."
    base="${engine%.engine}"
    layer_json="${base}.layers.json"
    build_log="${base}.build.log"

    [[ -r "$layer_json" ]] || die "Layer info missing for '$engine'.
       Expected '$layer_json'. Rebuild with --profilingVerbosity=detailed."

    bold "== $(basename "$engine") =="
    printf '  %-24s %s bytes\n' "engine size" "$(stat -c %s "$engine")"

    if [[ -r "$build_log" ]]; then
        printf '  %-24s %s\n' "requested flags" \
            "$(sed -n 's/^# command: //p' "$build_log" \
               | grep -oE -- '--(noTF32|fp16|int8|bf16|best|calib=[^ ]*)' | tr '\n' ' ')"
        printf '  %-24s %s\n' "warnings / errors" \
            "$(grep -c '\[W\]' "$build_log" || true) / $(grep -c '\[E\]' "$build_log" || true)"
    fi

    python3 - "$layer_json" <<'PY'
import json, sys
from collections import Counter

data   = json.load(open(sys.argv[1]))
layers = data.get("Layers", [])

def datatypes(layer, key):
    return [t.get("Format/Datatype") for t in layer.get(key, []) if t.get("Format/Datatype")]

# A layer's compute precision is best represented by its weights (where it has
# them) and its output tensor datatype.
weights = Counter(l["Weights"]["Type"] for l in layers if isinstance(l.get("Weights"), dict))
outputs = Counter(t for l in layers for t in datatypes(l, "Outputs"))
kinds   = Counter(l.get("LayerType") for l in layers)

print(f"  {'fused layers':<24} {len(layers)}")
print(f"  {'layer types':<24} " + ", ".join(f"{k}={v}" for k, v in kinds.most_common()))
print(f"  {'weight datatypes':<24} " + ", ".join(f"{k}={v}" for k, v in weights.most_common()))
print(f"  {'output datatypes':<24} " + ", ".join(f"{k}={v}" for k, v in outputs.most_common()))

# Per-layer breakdown for anything not running at the dominant precision.
if weights:
    dominant = weights.most_common(1)[0][0]
    odd = [l for l in layers
           if isinstance(l.get("Weights"), dict) and l["Weights"]["Type"] != dominant]
    print(f"  {'dominant weight type':<24} {dominant}")
    print(f"  {'layers off dominant':<24} {len(odd)}")
    for l in odd[:20]:
        name = l["Name"]
        name = name if len(name) <= 68 else name[:65] + "..."
        print(f"      {l['Weights']['Type']:<6} {name}")
PY
    info ""
done

bold "Report complete."
