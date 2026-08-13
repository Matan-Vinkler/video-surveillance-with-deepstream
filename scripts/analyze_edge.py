#!/usr/bin/env python3
"""analyze_edge.py - Milestone 8.2 analysis of the telemetry measure_edge.sh collects.

Reads four files written by one run and reports statistics. It asserts nothing
and tunes nothing; it turns raw telemetry into figures, and every figure it
prints is traceable to a line in one of those files.

    models/edge/<mode>_app.log         host-timestamped deepstream-app output
    models/edge/<mode>_tegrastats.txt  tegrastats --interval 1000
    models/edge/<mode>_sampler.tsv     1 Hz RSS / MemAvailable / GPU clock / cooling
    models/edge/<mode>_summary.txt     run metadata and the epoch marks

Three parsing rules, all established by the Milestone 8.2 pilot:

  * `**PERF:  FPS 0 (Avg)` is a HEADER, reprinted every 20 samples. It is not a
    sample and is excluded by requiring a numeric field.
  * GStreamer's `Got data flow before segment event` warning fires exactly once
    per file-loop seek. It is the INDEPENDENT loop counter: completed loops x 288
    frames, timed from the marker timestamps, owes nothing to DeepStream's own
    reporting. It is counted, never suppressed.
  * Empty lines in the application log are kept as evidence and counted
    separately so they cannot be mistaken for missing data.

Usage:  ./scripts/analyze_edge.py --soak
"""

import datetime
import math
import re
import sys
from pathlib import Path

FRAMES_PER_LOOP = 288          # sample_walk.mov, established in Milestone 2
REALTIME_FPS = 29.97           # the input stream's rate; the requirement
WARMUP_S = 60                  # validated in the pilot: RSS plateaus by t+19 s

REPO = Path(__file__).resolve().parent.parent
EDGE = REPO / "models" / "edge"


# ----------------------------------------------------------------- helpers --
def pct(sorted_vals, q):
    if not sorted_vals:
        return float("nan")
    i = (len(sorted_vals) - 1) * q
    lo = int(math.floor(i))
    hi = min(lo + 1, len(sorted_vals) - 1)
    return sorted_vals[lo] + (sorted_vals[hi] - sorted_vals[lo]) * (i - lo)


def stats(vals):
    if not vals:
        return None
    s = sorted(vals)
    n = len(s)
    mean = sum(s) / n
    var = sum((v - mean) ** 2 for v in s) / n
    return dict(n=n, mean=mean, median=pct(s, 0.5), min=s[0], p5=pct(s, 0.05),
                p95=pct(s, 0.95), max=s[-1], sd=math.sqrt(var))


def fmt(st, unit=""):
    if st is None:
        return "no samples"
    return (f"n={st['n']} mean={st['mean']:.2f}{unit} median={st['median']:.2f}{unit} "
            f"min={st['min']:.2f}{unit} p5={st['p5']:.2f}{unit} p95={st['p95']:.2f}{unit} "
            f"max={st['max']:.2f}{unit} sd={st['sd']:.2f}")


def slope_per_min(points):
    """Least-squares slope of y against t (seconds), returned per minute."""
    n = len(points)
    if n < 3:
        return float("nan")
    sx = sum(p[0] for p in points)
    sy = sum(p[1] for p in points)
    sxy = sum(p[0] * p[1] for p in points)
    sxx = sum(p[0] ** 2 for p in points)
    denom = n * sxx - sx * sx
    if denom == 0:
        return float("nan")
    return ((n * sxy - sx * sy) / denom) * 60.0


def rng(vals, scale=1.0, f="{:.1f}"):
    if not vals:
        return "no samples"
    return f"{f.format(min(vals) / scale)} - {f.format(max(vals) / scale)}"


# ------------------------------------------------------------------ parse ---
def read_summary(path):
    marks = {}
    for line in path.read_text().splitlines():
        parts = line.split(None, 1)
        if len(parts) == 2 and not line.startswith(" "):
            marks[parts[0]] = parts[1].strip()
    return marks


def read_app_log(path):
    perf, loops, empty, total = [], [], 0, 0
    perf_re = re.compile(r"\*\*PERF:\s+([0-9]+\.[0-9]+)\s+\(([0-9]+\.[0-9]+)\)")
    for line in path.read_text(errors="replace").splitlines():
        total += 1
        parts = line.split(None, 1)
        if not parts:
            continue
        try:
            ts = float(parts[0])
        except ValueError:
            continue
        if len(parts) == 1:
            empty += 1
            continue
        body = parts[1]
        m = perf_re.search(body)
        if m:                                   # header lines carry no number
            perf.append((ts, float(m.group(1)), float(m.group(2))))
        if "Got data flow before segment event" in body:
            loops.append(ts)
    return perf, loops, empty, total


def read_tegrastats(path):
    pats = {
        "ram":  re.compile(r"RAM (\d+)/(\d+)MB"),
        "lfb":  re.compile(r"lfb (\d+)x(\d+)MB"),
        "gr3d": re.compile(r"GR3D_FREQ (\d+)%"),
        "cpu":  re.compile(r"CPU \[([^\]]*)\]"),
        "vin":  re.compile(r"VDD_IN (\d+)mW"),
        "vcg":  re.compile(r"VDD_CPU_GPU_CV (\d+)mW"),
        "vsoc": re.compile(r"VDD_SOC (\d+)mW"),
    }
    temp_re = re.compile(r"\b(cpu|gpu|tj|soc0|soc1|soc2)@([\d.]+)C")
    head_re = re.compile(r"^(\d\d)-(\d\d)-(\d{4}) (\d\d):(\d\d):(\d\d)")
    out = []
    for line in path.read_text(errors="replace").splitlines():
        h = head_re.match(line)
        if not h:
            continue
        mo, d, y, H, M, S = (int(x) for x in h.groups())
        ts = datetime.datetime(y, mo, d, H, M, S).timestamp()
        row = {"ts": ts}
        m = pats["ram"].search(line)
        if m:
            row["ram_mb"], row["ram_total_mb"] = int(m.group(1)), int(m.group(2))
        m = pats["lfb"].search(line)
        if m:
            row["lfb_mb"] = int(m.group(1)) * int(m.group(2))
        for key in ("gr3d", "vin", "vcg", "vsoc"):
            m = pats[key].search(line)
            if m:
                row[key] = int(m.group(1))
        m = pats["cpu"].search(line)
        if m:
            cores = [c.split("@") for c in m.group(1).split(",")]
            row["cpu_util"] = [int(c[0].rstrip("%")) for c in cores]
            row["cpu_mhz"] = [int(c[1]) for c in cores]
        row["temps"] = {k: float(v) for k, v in temp_re.findall(line)}
        out.append(row)
    return out


def read_sampler(path):
    lines = path.read_text().splitlines()
    hdr = lines[0].lstrip("#").strip().split("\t")
    rows = []
    for line in lines[1:]:
        f = line.split("\t")
        if len(f) != len(hdr):
            continue
        rows.append(dict(zip(hdr, f)))
    return hdr, rows


# ------------------------------------------------------------------- main ---
def main():
    mode = None
    for a in sys.argv[1:]:
        if a in ("--pilot", "--soak"):
            mode = a[2:]
        elif a in ("-h", "--help"):
            print(__doc__)
            return 0
        else:
            print(f"Unknown option {a!r}. Try --help.", file=sys.stderr)
            return 2
    if mode is None:
        print("Pick --pilot or --soak.", file=sys.stderr)
        return 2

    paths = {k: EDGE / f"{mode}_{k}" for k in
             ("app.log", "tegrastats.txt", "sampler.tsv", "summary.txt")}
    missing = [str(p) for p in paths.values() if not p.exists()]
    if missing:
        print("Missing telemetry:\n  " + "\n  ".join(missing), file=sys.stderr)
        return 4

    marks = read_summary(paths["summary.txt"])
    perf, loops, empty, total_lines = read_app_log(paths["app.log"])
    tegra = read_tegrastats(paths["tegrastats.txt"])
    hdr, srows = read_sampler(paths["sampler.tsv"])

    t_base = float(marks.get("baseline_start", 0) or 0)
    t_load = float(marks.get("load_start", 0) or 0)
    t_end = float(marks.get("load_end", 0) or 0)
    t_steady = t_load + WARMUP_S

    out = []
    def p(s=""):
        out.append(s)
        print(s)

    p("=" * 78)
    p(f"Milestone 8.2 edge characterisation - {mode} run")
    p("=" * 78)
    p(f"status {marks.get('status')}   abort_reason {marks.get('abort_reason')}   "
      f"app_exit_code {marks.get('app_exit_code')}   stop_rung {marks.get('stop_rung')}")
    p(f"load window {t_end - t_load:.0f} s   idle baseline {t_load - t_base:.0f} s   "
      f"steady window = load + {WARMUP_S} s onward")
    p(f"engine sha256 {marks.get('engine_sha256')}")

    # ---------------------------------------------------------------- PERF --
    p("\n" + "-" * 78)
    p("1. THROUGHPUT - DeepStream **PERF (self-reported)")
    p("-" * 78)
    all_v = [v for _, v, _ in perf]
    steady = [(ts, v) for ts, v, _ in perf if ts >= t_steady]
    p(f"  all data samples        {fmt(stats(all_v))}")
    p(f"  steady window (t+{WARMUP_S}s+)  {fmt(stats([v for _, v in steady]))}")
    for label, vals in (("all", all_v), ("steady", [v for _, v in steady])):
        if vals:
            ok = sum(1 for v in vals if v >= REALTIME_FPS)
            p(f"  {label:<6} samples >= {REALTIME_FPS} fps: {ok}/{len(vals)} = {100 * ok / len(vals):.1f}%")
    if perf:
        p(f"  deepstream-app final cumulative average: {perf[-1][2]:.2f} fps")
    p("  No samples were discarded. Low values are data, not noise.")

    # --------------------------------------------------------------- loops --
    p("\n" + "-" * 78)
    p("2. THROUGHPUT - independent cross-check from file-loop markers")
    p("-" * 78)
    p(f"  loop markers in log: {len(loops)}   (GStreamer per-seek warning, one per loop)")
    steady_loops = [t for t in loops if t >= t_steady]
    if len(steady_loops) >= 3:
        periods = [b - a for a, b in zip(steady_loops, steady_loops[1:])]
        span = steady_loops[-1] - steady_loops[0]
        completed = len(steady_loops) - 1
        indep = FRAMES_PER_LOOP * completed / span
        p(f"  steady-state loops     {completed} completed in {span:.2f} s")
        p(f"  loop period            mean {span / completed:.4f} s  "
          f"min {min(periods):.4f} s  max {max(periods):.4f} s")
        p(f"  frames                 {completed} x {FRAMES_PER_LOOP} = {completed * FRAMES_PER_LOOP} "
          f"(independent count, not derived from PERF)")
        p(f"  independent throughput {indep:.2f} fps")
        st = stats([v for _, v in steady])
        if st:
            d = indep - st["mean"]
            p(f"  vs PERF steady mean    {st['mean']:.2f} fps   difference {d:+.2f} fps "
              f"({100 * abs(d) / st['mean']:.2f}%)")
            p("  The two measure slightly different things: PERF is the app's own per-interval")
            p("  count, the loop figure is whole clips divided by wall time. They are not")
            p("  forced to agree; the gap is reported as measured.")
    else:
        p("  Too few loop markers for an independent figure.")

    # ------------------------------------------------- loop boundary effect --
    if steady and len(steady_loops) >= 3:
        with_b, without = [], []
        for i, (ts, v) in enumerate(steady):
            lo = steady[i - 1][0] if i else ts - 1
            (with_b if any(lo < m <= ts for m in steady_loops) else without).append(v)
        p(f"  PERF windows containing a loop boundary: n={len(with_b)} "
          f"mean={sum(with_b) / len(with_b):.2f} fps" if with_b else "  no bounded windows")
        if without:
            p(f"  PERF windows with no loop boundary:      n={len(without)} "
              f"mean={sum(without) / len(without):.2f} fps")
        if with_b and without:
            d = sum(without) / len(without) - sum(with_b) / len(with_b)
            p(f"  difference {d:+.2f} fps - reported for transparency; boundary samples are")
            p("  NOT excluded from the statistics above.")

    # ----------------------------------------------------------------- RSS --
    p("\n" + "-" * 78)
    p("3. MEMORY - deepstream-app VmRSS and system MemAvailable")
    p("-" * 78)
    rss = [(float(r["epoch"]), int(r["rss_kb"])) for r in srows if r["rss_kb"].isdigit()]
    rss_steady = [(ts, v) for ts, v in rss if ts >= t_steady]
    if rss_steady:
        first, last = rss_steady[0][1], rss_steady[-1][1]
        sl = slope_per_min([(ts - rss_steady[0][0], v / 1024.0) for ts, v in rss_steady])
        p(f"  steady window start    {first / 1024:.1f} MB   ({len(rss_steady)} samples)")
        p(f"  steady window min/max  {min(v for _, v in rss_steady) / 1024:.1f} / "
          f"{max(v for _, v in rss_steady) / 1024:.1f} MB")
        p(f"  final                  {last / 1024:.1f} MB")
        p(f"  total change           {(last - first) / 1024:+.2f} MB over "
          f"{rss_steady[-1][0] - rss_steady[0][0]:.0f} s")
        p(f"  fitted slope           {sl:+.4f} MB/min")
        p(f"  Warmup (first {WARMUP_S} s) excluded from the fit: Triton model load, CUDA context")
        p("  and buffer-pool allocation all happen there and are not growth.")
        p("  A bounded run cannot establish the presence or absence of a leak; only what")
        p("  was observed over this window is reported.")
    mem = [int(r["memavail_kb"]) for r in srows if r["memavail_kb"].isdigit()]
    if mem:
        p(f"  MemAvailable           min {min(mem) / 1024:.0f} MB   max {max(mem) / 1024:.0f} MB")
        p(f"  Safety floor is {int(marks.get('ram_floor_kb', 614400)) / 1024:.0f} MB - OUR conservative threshold "
          "because this board has no")
        p("  swap. It is not the kernel's OOM threshold and is not a prediction of one.")

    # --------------------------------------------------- tegrastats windows --
    p("\n" + "-" * 78)
    p("4. SYSTEM TELEMETRY - idle baseline vs loaded (tegrastats, whole board)")
    p("-" * 78)
    idle = [r for r in tegra if t_base <= r["ts"] < t_load]
    load = [r for r in tegra if t_steady <= r["ts"] <= t_end]

    def col(rows, key):
        return [r[key] for r in rows if key in r]

    def temps(rows, name):
        return [r["temps"][name] for r in rows if name in r.get("temps", {})]

    def cpu_mean(rows):
        return [sum(r["cpu_util"]) / len(r["cpu_util"]) for r in rows if "cpu_util" in r]

    def cpu_peak_mhz(rows):
        return [max(r["cpu_mhz"]) for r in rows if "cpu_mhz" in r]

    p(f"  {'metric':<22} {'idle baseline':<26} {'loaded (steady)':<26}")
    rowspec = [
        ("RAM used (MB)", lambda r: col(r, "ram_mb"), 1.0, "{:.0f}"),
        ("lfb (MB)", lambda r: col(r, "lfb_mb"), 1.0, "{:.0f}"),
        ("GR3D_FREQ (%)", lambda r: col(r, "gr3d"), 1.0, "{:.0f}"),
        ("CPU mean-core (%)", cpu_mean, 1.0, "{:.1f}"),
        ("CPU peak clock (MHz)", cpu_peak_mhz, 1.0, "{:.0f}"),
        ("tj (C)", lambda r: temps(r, "tj"), 1.0, "{:.1f}"),
        ("gpu temp (C)", lambda r: temps(r, "gpu"), 1.0, "{:.1f}"),
        ("cpu temp (C)", lambda r: temps(r, "cpu"), 1.0, "{:.1f}"),
        ("VDD_IN (W)", lambda r: col(r, "vin"), 1000.0, "{:.2f}"),
        ("VDD_CPU_GPU_CV (W)", lambda r: col(r, "vcg"), 1000.0, "{:.2f}"),
        ("VDD_SOC (W)", lambda r: col(r, "vsoc"), 1000.0, "{:.2f}"),
    ]
    for name, get, scale, f in rowspec:
        p(f"  {name:<22} {rng(get(idle), scale, f):<26} {rng(get(load), scale, f):<26}")
    p(f"  tegrastats samples     idle {len(idle)}, loaded {len(load)}")
    p("  tegrastats measures the whole Jetson, not the container: the desktop session is")
    p("  a standing consumer, which is why the idle column exists.")

    ghz = [int(r["gpu_hz"]) for r in srows if r["gpu_hz"].isdigit()]
    ghz_idle = [int(r["gpu_hz"]) for r in srows
                if r["gpu_hz"].isdigit() and float(r["epoch"]) < t_load]
    ghz_load = [int(r["gpu_hz"]) for r in srows
                if r["gpu_hz"].isdigit() and float(r["epoch"]) >= t_steady]
    p(f"  GPU devfreq (MHz)      {rng(ghz_idle, 1e6, '{:.0f}'):<26} {rng(ghz_load, 1e6, '{:.0f}'):<26}")
    if ghz_load:
        p(f"  GPU clock mean under load: {sum(ghz_load) / len(ghz_load) / 1e6:.0f} MHz "
          "(tegrastats reports GPU LOAD, not clock; this comes from devfreq sysfs)")

    # ------------------------------------------------------------- cooling --
    p("\n" + "-" * 78)
    p("5. THERMAL COOLING DEVICES - direct throttling evidence")
    p("-" * 78)
    p("  Class A imposes frequency caps: a non-zero state IS the thermal framework")
    p("  throttling the hardware. Class B are alert and fan devices: a fan stepping up")
    p("  is thermal management working, and is not throttling.")
    engaged_a = []
    for i, name in enumerate(hdr[4:], start=4):
        vals = [(float(r["epoch"]), int(r[name])) for r in srows if r[name].strip().isdigit()]
        if not vals:
            continue
        cls = "A" if name.startswith(("cpufreq-", "devfreq-")) else "B"
        mx = max(v for _, v in vals)
        trans = [(ts, v) for (pts, pv), (ts, v) in zip(vals, vals[1:]) if pv == 0 and v > 0]
        line = f"  [{cls}] {name:<26} start={vals[0][1]} max_observed={mx}"
        if mx > 0:
            line += f"  ENGAGED, {len(trans)} zero-to-nonzero transition(s)"
            if cls == "A":
                engaged_a.append(name)
        p(line)
        for ts, v in trans[:5]:
            p(f"        first transitions: t+{ts - t_load:.0f}s -> state {v}")
    p("")
    if engaged_a:
        p(f"  *** Class A ENGAGED: {', '.join(engaged_a)} - the thermal framework applied")
        p("      frequency capping during this run. This is direct evidence of throttling.")
    else:
        p("  No Class A device left state 0 at any point: the kernel's thermal framework")
        p("  applied no frequency capping during this run. That is a statement about")
        p("  measured cooling-device state, not an inference from clocks.")

    # --------------------------------------------------- early vs late drift --
    p("\n" + "-" * 78)
    p("6. DEGRADATION OVER TIME - early vs late steady state")
    p("-" * 78)
    if steady and load:
        span = t_end - t_steady
        third = span / 3.0
        def window(rows, getter, lo, hi):
            return [v for r, v in ((r, getter(r)) for r in rows)
                    if v is not None and lo <= r["ts"] - t_steady <= hi]
        early_p = [v for ts, v in steady if ts - t_steady <= third]
        late_p = [v for ts, v in steady if ts - t_steady >= 2 * third]
        rows_early = [r for r in load if r["ts"] - t_steady <= third]
        rows_late = [r for r in load if r["ts"] - t_steady >= 2 * third]

        def mean(x):
            return sum(x) / len(x) if x else float("nan")

        p(f"  {'metric':<22} {'first third':>14} {'last third':>14} {'change':>12}")
        pairs = [
            ("PERF fps", mean(early_p), mean(late_p)),
            ("GR3D_FREQ %", mean(col(rows_early, "gr3d")), mean(col(rows_late, "gr3d"))),
            ("CPU mean-core %", mean(cpu_mean(rows_early)), mean(cpu_mean(rows_late))),
            ("tj C", mean(temps(rows_early, "tj")), mean(temps(rows_late, "tj"))),
            ("VDD_IN W", mean(col(rows_early, "vin")) / 1000, mean(col(rows_late, "vin")) / 1000),
            ("RAM used MB", mean(col(rows_early, "ram_mb")), mean(col(rows_late, "ram_mb"))),
        ]
        gl = [v for ts, v in ((float(r["epoch"]), int(r["gpu_hz"])) for r in srows
                              if r["gpu_hz"].isdigit()) if ts >= t_steady]
        if gl:
            n3 = max(1, len(gl) // 3)
            pairs.append(("GPU clock MHz", mean(gl[:n3]) / 1e6, mean(gl[-n3:]) / 1e6))
        rs = [v for ts, v in rss_steady]
        if rs:
            n3 = max(1, len(rs) // 3)
            pairs.append(("RSS MB", mean(rs[:n3]) / 1024, mean(rs[-n3:]) / 1024))
        for name, a, b in pairs:
            p(f"  {name:<22} {a:>14.2f} {b:>14.2f} {b - a:>+12.2f}")
        if not math.isnan(mean(early_p)) and mean(early_p):
            drift = 100 * (mean(late_p) - mean(early_p)) / mean(early_p)
            verdict = ("stable" if abs(drift) < 1 else
                       "declined" if drift < 0 else "improved")
            p(f"\n  Throughput {verdict}: {drift:+.2f}% from first third to last third.")
        sl_fps = slope_per_min([(ts - t_steady, v) for ts, v in steady])
        p(f"  Fitted throughput trend: {sl_fps:+.3f} fps/min over the steady window.")
        p("  GPU clock movement under a load-following governor is ordinary DVFS, not")
        p("  throttling; throttling is what section 5 measures.")

    # ---------------------------------------------------------- log hygiene --
    p("\n" + "-" * 78)
    p("7. LOG ACCOUNTING")
    p("-" * 78)
    p(f"  application log lines  {total_lines}")
    p(f"  PERF data samples      {len(perf)}")
    p(f"  PERF header lines      {marks.get('perf_header_lines', '?')} (excluded: '**PERF: FPS 0 (Avg)')")
    p(f"  loop markers           {len(loops)}")
    p(f"  empty lines            {empty}  (kept in the log as evidence, counted here so")
    p("                         they cannot be mistaken for missing output)")

    (EDGE / f"{mode}_analysis.txt").write_text("\n".join(out) + "\n")
    print(f"\nWritten: {EDGE / (mode + '_analysis.txt')}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
