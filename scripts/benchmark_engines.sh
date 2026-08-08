#!/usr/bin/env bash
# benchmark_engines.sh - compare the built TensorRT engines fairly.
#
# Building and benchmarking are separate operations: this script only loads
# already-built engines, so no builder work can perturb a timing.
#
# The GPU clock cannot be locked on this machine (jetson_clocks needs root, and
# no sudo is available), so DVFS will move the GPU between 306 and 1020 MHz
# during the run. That cannot be eliminated, only accounted for:
#
#   * runs are INTERLEAVED round-robin (fp32, fp16, int8, fp32, ...) rather than
#     grouped, so a monotonic thermal or clock drift cannot be mistaken for a
#     property of whichever engine ran last;
#   * each engine is measured REPS times and the spread is reported, never a
#     single number;
#   * a cool-down separates runs, and tj temperature is recorded around each;
#   * tegrastats runs throughout, recording clock, load, power and temperature;
#   * if the within-engine spread approaches the between-engine difference, the
#     comparison is reported as INCONCLUSIVE rather than being presented as a
#     result.
#
# Usage:
#   ./scripts/benchmark_engines.sh
#   ./scripts/benchmark_engines.sh --reps 3 --duration 60 --cooldown 30

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/trt_common.sh"

REPS="${REPS:-3}"
DURATION="${DURATION:-60}"
WARMUP_MS="${WARMUP_MS:-5000}"
ITERATIONS="${ITERATIONS:-1000}"
AVG_RUNS="${AVG_RUNS:-100}"
COOLDOWN="${COOLDOWN:-30}"
BUSY_LIMIT="${BUSY_LIMIT:-40}"

while (( $# > 0 )); do
    case "$1" in
        --reps)     shift; (( $# > 0 )) || die "--reps needs a value.";     REPS="$1" ;;
        --duration) shift; (( $# > 0 )) || die "--duration needs a value."; DURATION="$1" ;;
        --cooldown) shift; (( $# > 0 )) || die "--cooldown needs a value."; COOLDOWN="$1" ;;
        -h|--help)  sed -n '2,30p' "$0"; exit 0 ;;
        *) die "Unknown option '$1'. Try --help." ;;
    esac
    shift
done

[[ "$REPS"     =~ ^[1-9][0-9]*$ ]] || die "--reps must be a positive integer, got '$REPS'."
[[ "$DURATION" =~ ^[1-9][0-9]*$ ]] || die "--duration must be a positive integer, got '$DURATION'."
[[ "$COOLDOWN" =~ ^[0-9]+$ ]]      || die "--cooldown must be a non-negative integer, got '$COOLDOWN'."

require_tools
require_trtexec

PRECISIONS=(fp32 fp16 int8)

# Resolve the shape from the model contract, so the benchmark cannot silently
# use a different shape than the engines were built for.
CONTRACT="$(mktemp)"
trap 'rm -f "$CONTRACT"' EXIT
model_contract >"$CONTRACT" || die "TensorRT could not parse the ONNX model."
INPUT_NAME="$(contract_field "$CONTRACT" input_name)"
INPUT_C="$(contract_field "$CONTRACT" input_c)"
INPUT_H="$(contract_field "$CONTRACT" input_h)"
INPUT_W="$(contract_field "$CONTRACT" input_w)"
SHAPE_SPEC="'${INPUT_NAME}':${ENGINE_BATCH}x${INPUT_C}x${INPUT_H}x${INPUT_W}"

declare -A ENGINE
for precision in "${PRECISIONS[@]}"; do
    path="$(engine_path "$precision" "$INPUT_W" "$INPUT_H")"
    [[ -s "$path" ]] || die "Engine for '$precision' is missing: '$path'.
       Build it first:  ./scripts/build_engines.sh --precision $precision"
    ENGINE["$precision"]="$path"
done

RESULTS="$ENGINE_DIR/benchmark_results.tsv"
TEGRA_LOG="$ENGINE_DIR/tegrastats_benchmark.txt"

bold "== Benchmark configuration =="
printf '  %-24s %s\n' "engines" "${PRECISIONS[*]}"
printf '  %-24s %s\n' "shape (all engines)" "$SHAPE_SPEC"
printf '  %-24s %s\n' "batch" "$ENGINE_BATCH"
printf '  %-24s %s\n' "repetitions" "$REPS"
printf '  %-24s %s ms\n' "warm-up" "$WARMUP_MS"
printf '  %-24s %s s\n' "duration per run" "$DURATION"
printf '  %-24s %s\n' "min iterations" "$ITERATIONS"
printf '  %-24s %s s\n' "cool-down between runs" "$COOLDOWN"
printf '  %-24s %s\n' "power mode" "$(power_mode)"
printf '  %-24s %s\n' "order" "interleaved round-robin"

bold "== Process isolation check =="
busy="$(gpu_busy_percent)"
printf '  %-24s %s%%\n' "GPU busy (4s peak)" "$busy"
if (( busy > BUSY_LIMIT )); then
    die "GPU is $busy% busy before the benchmark started (limit $BUSY_LIMIT%).
       Something else is using the GPU. Stop any DeepStream pipeline or visible
       playback and re-run, or the measurements will not be comparable."
fi
printf '  %-24s %s C\n' "tj temperature" "$(tj_temp_c)"
printf '  %-24s %s MHz\n' "GPU clock" "$(gpu_cur_freq_mhz)"
info ""

# tegrastats runs for the whole benchmark, so every measurement has matching
# clock/thermal/power telemetry.
rm -f "$TEGRA_LOG"
tegrastats --interval 1000 --logfile "$TEGRA_LOG" >/dev/null 2>&1 &
TEGRA_PID=$!
cleanup() {
    kill "$TEGRA_PID" 2>/dev/null || true
    wait "$TEGRA_PID" 2>/dev/null || true
    rm -f "$CONTRACT"
}
trap cleanup EXIT

printf 'precision\trep\tthroughput_qps\tgpu_mean_ms\tgpu_median_ms\tgpu_min_ms\tgpu_p99_ms\tlat_mean_ms\tlat_median_ms\ttj_before\ttj_after\tclk_before\tclk_after\texit\n' >"$RESULTS"

# The GPU idles at its minimum clock (306 MHz here) and DVFS takes time to ramp.
# Without this, whichever engine runs first is measured on a cold, slow GPU and
# is systematically penalised -- observed directly: 306 MHz for run 1 against
# 816 MHz for run 3. A discarded pre-heat leaves the GPU warm and at a high
# clock before the first measured run.
bold "== GPU pre-heat (discarded, not a measurement) =="
printf '  %-24s %s MHz\n' "clock before pre-heat" "$(gpu_cur_freq_mhz)"
preheat_rc=0
trtexec "--loadEngine=${ENGINE[fp32]}" "--shapes=$SHAPE_SPEC" \
        --warmUp=2000 --duration=20 --useSpinWait \
        >"$ENGINE_DIR/preheat.log" 2>&1 || preheat_rc=$?
(( preheat_rc == 0 )) || die "GPU pre-heat run failed (exit $preheat_rc). See $ENGINE_DIR/preheat.log"
printf '  %-24s %s MHz\n' "clock after pre-heat" "$(gpu_cur_freq_mhz)"
printf '  %-24s %s C\n' "tj after pre-heat" "$(tj_temp_c)"
info ""

metric() {
    # metric <logfile> <label> <field>  e.g. metric log "GPU Compute Time" median
    sed -n "s/.*$2: .*$3 = \([0-9.]*\) ms.*/\1/p" "$1" | head -n1
}

run_index=0
for (( rep = 1; rep <= REPS; rep++ )); do
    for precision in "${PRECISIONS[@]}"; do
        run_index=$(( run_index + 1 ))
        engine="${ENGINE[$precision]}"
        log="$ENGINE_DIR/bench_${precision}_run${rep}.log"
        times="$ENGINE_DIR/times_${precision}_run${rep}.json"

        if (( run_index > 1 && COOLDOWN > 0 )); then
            printf '  cool-down %ss...\n' "$COOLDOWN"
            sleep "$COOLDOWN"
        fi

        tj_before="$(tj_temp_c)"
        clk_before="$(gpu_cur_freq_mhz)"
        bold "-- run $run_index/$(( REPS * ${#PRECISIONS[@]} )): $precision rep $rep --"
        printf '  %-24s %s C / %s MHz\n' "tj, clock before" "$tj_before" "$clk_before"

        cmd=(
            trtexec
            "--loadEngine=$engine"
            "--shapes=$SHAPE_SPEC"
            "--warmUp=$WARMUP_MS"
            "--duration=$DURATION"
            "--iterations=$ITERATIONS"
            "--avgRuns=$AVG_RUNS"
            --percentile=50,90,95,99
            --useSpinWait
            --separateProfileRun
            "--exportTimes=$times"
        )
        { printf '# command: %s\n' "${cmd[*]}"; printf '# started: %s\n' "$(date -Is)"; } >"$log"

        rc=0
        "${cmd[@]}" >>"$log" 2>&1 || rc=$?
        # Sampled immediately, before the cool-down, so it reflects the clock the
        # run actually settled at rather than the idle clock.
        clk_after="$(gpu_cur_freq_mhz)"
        tj_after="$(tj_temp_c)"

        qps="$(sed -n 's/.*Throughput: \([0-9.]*\) qps.*/\1/p' "$log" | head -n1)"
        gpu_mean="$(metric   "$log" "GPU Compute Time" mean)"
        gpu_median="$(metric "$log" "GPU Compute Time" median)"
        gpu_min="$(metric    "$log" "GPU Compute Time" min)"
        gpu_p99="$(sed -n 's/.*GPU Compute Time: .*percentile(99%) = \([0-9.]*\) ms.*/\1/p' "$log" | head -n1)"
        lat_mean="$(metric   "$log" "Latency" mean)"
        lat_median="$(metric "$log" "Latency" median)"

        if (( rc != 0 )) || [[ -z "$qps" || -z "$gpu_median" ]]; then
            printf '\n  --- last 20 log lines ---\n' >&2
            tail -n 20 "$log" >&2
            die "Benchmark run failed for $precision rep $rep (exit $rc). Log: $log"
        fi

        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$precision" "$rep" "$qps" "$gpu_mean" "$gpu_median" "$gpu_min" \
            "$gpu_p99" "$lat_mean" "$lat_median" "$tj_before" "$tj_after" \
            "$clk_before" "$clk_after" "$rc" >>"$RESULTS"

        printf '  %-24s %s qps\n' "throughput" "$qps"
        printf '  %-24s %s ms (median), %s ms (mean)\n' "GPU compute" "$gpu_median" "$gpu_mean"
        printf '  %-24s %s ms (median)\n' "end-to-end latency" "$lat_median"
        printf '  %-24s %s C / %s MHz\n' "tj, clock after" "$tj_after" "$clk_after"
    done
done

kill "$TEGRA_PID" 2>/dev/null || true

bold "== Results =="
printf '  raw table: %s\n' "$RESULTS"
printf '  telemetry: %s\n' "$TEGRA_LOG"
info ""

RESULTS_FILE="$RESULTS" python3 - <<'PY'
import os, csv, statistics as st

rows = list(csv.DictReader(open(os.environ["RESULTS_FILE"]), delimiter="\t"))
by = {}
for r in rows:
    by.setdefault(r["precision"], []).append(r)

order = [p for p in ("fp32", "fp16", "int8") if p in by]

print(f"  {'engine':<8}{'GPU compute median (ms)':<34}{'throughput (qps)':<26}{'spread':>8}")
print(f"  {'':<8}{'min / median / max of reps':<34}{'min / median / max':<26}")
print("  " + "-" * 74)

summary = {}
for p in order:
    med = sorted(float(r["gpu_median_ms"]) for r in by[p])
    qps = sorted(float(r["throughput_qps"]) for r in by[p])
    spread = max(med) - min(med)
    summary[p] = {"median": st.median(med), "spread": spread, "qps": st.median(qps)}
    print(f"  {p:<8}{min(med):.3f} / {st.median(med):.3f} / {max(med):.3f}".ljust(44)
          + f"{min(qps):.1f} / {st.median(qps):.1f} / {max(qps):.1f}".ljust(26)
          + f"{spread:.3f}".rjust(8))

# The GPU clock is not lockable here, so it is reported as a measured condition
# rather than assumed constant.
print()
print("  Conditions actually experienced (clock MHz / tj C at end of each run):")
for p in order:
    clks = [r["clk_after"] for r in by[p]]
    tjs  = [r["tj_after"] for r in by[p]]
    print(f"    {p:<6} clock {', '.join(clks)}   tj {', '.join(tjs)}")

print()
base = summary.get("fp32")
if base:
    print("  Speedup vs FP32 baseline (median GPU compute):")
    for p in order:
        if p == "fp32":
            continue
        ratio = base["median"] / summary[p]["median"]
        diff  = base["median"] - summary[p]["median"]
        worst_spread = max(base["spread"], summary[p]["spread"])
        verdict = "INCONCLUSIVE" if worst_spread >= abs(diff) * 0.5 else "resolved"
        print(f"    fp32 -> {p:<5} {ratio:5.2f}x   difference {diff:+.3f} ms   "
              f"worst within-engine spread {worst_spread:.3f} ms   [{verdict}]")
    print()
    print("  A comparison is marked INCONCLUSIVE when the within-engine spread")
    print("  reaches half the between-engine difference: at that point run-to-run")
    print("  variation is not clearly smaller than the effect being measured.")
PY

bold "Benchmark complete."
