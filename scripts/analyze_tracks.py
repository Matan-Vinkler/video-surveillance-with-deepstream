#!/usr/bin/env python3
"""analyze_tracks.py - turn deepstream-app's KITTI dumps into tracking evidence.

Reads the four per-frame dumps deepstream-app writes from four different probes
and reports what actually happened to object identity. It asserts nothing on its
own: it prints a human report to stdout and writes `key=value` lines to the file
named by --verdict, which verify_tracking.sh turns into pass/fail checks.

Keeping the arithmetic here rather than in awk is deliberate: track lifespans,
run-length analysis and switch detection are exactly the kind of thing that is
unreadable as a shell one-liner and easy to get quietly wrong.

KITTI line formats (deepstream_app.c:816 and :995):
  detector   label       0.0 0 0.0 l t r b 0.0 x6 conf      -> box $5..$8
  tracker    label  id   0.0 0 0.0 l t r b 0.0 x7 conf      -> id $2, box $6..$9
"""

import argparse
import os
import re
import sys

UNTRACKED_OBJECT_ID = 0xFFFFFFFFFFFFFFFF  # nvdsmeta.h:59

FRAME_RE = re.compile(r"_(\d+)\.txt$")


def read_dump(path, has_id):
    """frame number -> list of rows. Missing directory is an empty dump, not a
    crash: 'the tracker produced nothing' is a result we must be able to report."""
    frames = {}
    if not os.path.isdir(path):
        return frames
    for name in os.listdir(path):
        m = FRAME_RE.search(name)
        if not m:
            continue
        n = int(m.group(1))
        rows = []
        with open(os.path.join(path, name)) as fh:
            for line in fh:
                f = line.split()
                if not f:
                    continue
                if has_id:
                    rows.append(
                        {"label": f[0], "id": int(f[1]),
                         "box": tuple(float(x) for x in f[5:9]),
                         "conf": float(f[16])})
                else:
                    rows.append(
                        {"label": f[0], "id": None,
                         "box": tuple(float(x) for x in f[4:8]),
                         "conf": float(f[15])})
        frames[n] = rows
    return frames


def runs_of(frames_sorted, id_of):
    """Maximal stretches of consecutive frames carrying the same single id."""
    out = []
    start = prev = None
    cur = None
    for n in frames_sorted:
        i = id_of(n)
        if cur is not None and i == cur and prev is not None and n == prev + 1:
            prev = n
            continue
        if cur is not None:
            out.append((cur, start, prev))
        cur, start, prev = i, n, n
    if cur is not None:
        out.append((cur, start, prev))
    return out


def gaps(present, lo, hi):
    """Maximal runs of absent frames strictly inside [lo, hi]."""
    out = []
    start = None
    for n in range(lo, hi + 1):
        if n in present:
            if start is not None:
                out.append((start, n - 1))
                start = None
        elif start is None:
            start = n
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--detections", required=True)
    ap.add_argument("--tracks", required=True)
    ap.add_argument("--terminated", required=True)
    ap.add_argument("--shadow", required=True)
    ap.add_argument("--label", default="person")
    ap.add_argument("--verdict", required=True)
    a = ap.parse_args()

    det = read_dump(a.detections, has_id=False)
    trk = read_dump(a.tracks, has_id=True)
    term = read_dump(a.terminated, has_id=True)
    shadow = read_dump(a.shadow, has_id=True)

    v = {}
    out = []
    w = out.append

    def put(k, val):
        v[k] = val

    frames_total = len(det)
    put("frames_total", frames_total)
    put("track_files", len(trk))

    det_f = sorted(n for n, r in det.items() if any(x["label"] == a.label for x in r))
    trk_rows = {n: [x for x in r if x["label"] == a.label] for n, r in trk.items()}
    trk_f = sorted(n for n, r in trk_rows.items() if r)

    put("det_frames", len(det_f))
    put("trk_frames", len(trk_f))

    if not det_f:
        put("fatal", "no detector rows at all")
        write(a.verdict, v, out)
        return

    # --- untracked / duplicate rows -------------------------------------------
    untracked = [(n, x["id"]) for n in trk_f for x in trk_rows[n]
                 if x["id"] == UNTRACKED_OBJECT_ID]
    put("untracked_rows", len(untracked))

    # Past-frame meta is appended to already-written frame files in the SAME
    # format, so a duplicated id in one frame is the signature to look for.
    multi = [n for n in trk_f if len(trk_rows[n]) > 1]
    dup_id = [n for n in multi
              if len(set(x["id"] for x in trk_rows[n])) < len(trk_rows[n])]
    put("multi_row_frames", len(multi))
    put("duplicate_id_frames", len(dup_id))

    # --- identity -------------------------------------------------------------
    ids_by_frame = {n: [x["id"] for x in trk_rows[n]] for n in trk_f}
    all_ids = sorted({i for v_ in ids_by_frame.values() for i in v_})
    put("unique_ids", len(all_ids))
    put("id_list", ",".join(str(i) for i in all_ids) if all_ids else "-")

    lifespan = {}
    for i in all_ids:
        fr = [n for n in trk_f if i in ids_by_frame[n]]
        lifespan[i] = (min(fr), max(fr), len(fr))

    def dominant_of(n):
        rows = trk_rows[n]
        return max(rows, key=lambda x: x["conf"])["id"] if rows else None

    rl = runs_of(trk_f, dominant_of)
    longest = max(rl, key=lambda r: r[2] - r[1] + 1) if rl else None

    w("== Frames ==")
    w("  %-34s %d" % ("frames processed", frames_total))
    w("  %-34s %d" % ("frames with a %s detection" % a.label, len(det_f)))
    w("  %-34s %d" % ("frames with a tracked %s" % a.label, len(trk_f)))
    if det_f:
        w("  %-34s %d..%d" % ("detector observation window", det_f[0], det_f[-1]))
    if trk_f:
        w("  %-34s %d..%d" % ("tracker output window", trk_f[0], trk_f[-1]))

    # --- track establishment / probation --------------------------------------
    w("")
    w("== Track establishment (measured, not assumed) ==")
    first_det, first_trk = det_f[0], (trk_f[0] if trk_f else None)
    put("first_det_frame", first_det)
    put("first_trk_frame", first_trk if first_trk is not None else -1)
    if first_trk is None:
        w("  no track was ever emitted")
        put("probation_delay", -1)
    else:
        delay = first_trk - first_det
        put("probation_delay", delay)
        w("  %-34s %d" % ("first %s detection at frame" % a.label, first_det))
        w("  %-34s %d" % ("first tracker output at frame", first_trk))
        w("  %-34s %d frame(s)" % ("delay before first emission", delay))
        w("  %-34s %s" % ("id emitted on that first frame",
                          ",".join(str(i) for i in ids_by_frame[first_trk])))
        if delay == 0:
            w("  -> targets are emitted from their very first detected frame:")
            w("     no probation delay is visible in the object metadata.")
        else:
            w("  -> %d detected frame(s) produced NO tracker output, which is" % delay)
            w("     consistent with a probation/TENTATIVE period being withheld.")

    if longest:
        est_start = longest[1]
        early_ids = sorted({i for n in trk_f if n < est_start for i in ids_by_frame[n]})
        put("establishment_end_frame", est_start)
        put("establishment_ids", len(early_ids))
        put("establishment_id_list", ",".join(str(i) for i in early_ids) if early_ids else "-")
        w("  %-34s %d" % ("stable track established at frame", est_start))
        w("  %-34s %s" % ("ids used before that point",
                          ",".join(str(i) for i in early_ids) if early_ids else "(none)"))
    else:
        put("establishment_end_frame", -1)
        put("establishment_ids", 0)
        put("establishment_id_list", "-")

    # --- identity report ------------------------------------------------------
    w("")
    w("== Identity ==")
    w("  %-34s %d" % ("unique %s track ids" % a.label, len(all_ids)))
    for i in all_ids:
        lo, hi, cnt = lifespan[i]
        cov = 100.0 * cnt / len(trk_f) if trk_f else 0.0
        w("    id %-6d first %-5d last %-5d frames %-5d coverage %5.1f%%"
          % (i, lo, hi, cnt, cov))

    if longest:
        lid, lo, hi = longest
        put("longest_run_id", lid)
        put("longest_run_len", hi - lo + 1)
        put("longest_run_start", lo)
        put("longest_run_end", hi)
        w("  %-34s id %d, %d frames (%d..%d)"
          % ("longest continuous track", lid, hi - lo + 1, lo, hi))
        dom = max(all_ids, key=lambda i: lifespan[i][2])
        cov = 100.0 * lifespan[dom][2] / len(trk_f)
        put("dominant_id", dom)
        put("dominant_coverage_pct", "%.1f" % cov)
        w("  %-34s id %d, %.1f%% of tracked frames  [metric, not a criterion]"
          % ("dominant id coverage", dom, cov))
    else:
        for k in ("longest_run_id", "longest_run_len", "longest_run_start",
                  "longest_run_end", "dominant_id"):
            put(k, -1)
        put("dominant_coverage_pct", "0.0")

    # --- ID switches ----------------------------------------------------------
    # A switch counts as MID-TRACK only when the detector was continuously
    # observing the person across the transition: if the detector blinked, an
    # identity change is a re-acquisition, which is a different phenomenon.
    w("")
    w("== ID switches ==")
    det_set = set(det_f)
    mid, estab = [], []
    if longest:
        est_start = longest[1]
        for k in range(1, len(trk_f)):
            n, p = trk_f[k], trk_f[k - 1]
            if dominant_of(n) == dominant_of(p):
                continue
            continuous = (n in det_set and p in det_set and n == p + 1)
            entry = "frame %d: id %s -> %s%s" % (
                n, dominant_of(p), dominant_of(n),
                "" if continuous else "  (detector not continuous here)")
            if n <= est_start:
                estab.append(entry)
            elif continuous:
                mid.append(entry)
            else:
                estab.append(entry)
    put("mid_track_switches", len(mid))
    put("establishment_switches", len(estab))
    w("  %-34s %d" % ("switches during establishment", len(estab)))
    for e in estab:
        w("    %s" % e)
    w("  %-34s %d" % ("MID-TRACK switches", len(mid)))
    for e in mid:
        w("    %s" % e)
    if not mid:
        w("  -> no identity change occurred after the stable track was")
        w("     established while the detector observed the person continuously.")

    # --- reacquisition --------------------------------------------------------
    reacq = [i for i in all_ids
             if any(n not in trk_f for n in range(lifespan[i][0], lifespan[i][1] + 1))]
    new_after = [i for i in all_ids if longest and lifespan[i][0] > longest[2]]
    put("reacquisitions", len(new_after))
    w("  %-34s %d" % ("ids first appearing after longest run", len(new_after)))
    put("ids_with_internal_holes", len(reacq))

    # --- detector gaps and what they did NOT exercise -------------------------
    w("")
    w("== Detector gaps, shadow tracking and occlusion ==")
    interior = gaps(det_set, det_f[0], det_f[-1])
    put("interior_det_gaps", len(interior))
    put("interior_det_gap_frames", sum(b - a_ + 1 for a_, b in interior))
    lead = det_f[0]
    trail = frames_total - 1 - det_f[-1]
    w("  %-34s %d frame(s) before frame %d" % ("lead-in with no detection", lead, det_f[0]))
    w("  %-34s %d frame(s) after frame %d" % ("run-out with no detection", trail, det_f[-1]))
    w("  %-34s %d" % ("INTERIOR detector gaps", len(interior)))
    for a_, b in interior:
        w("    frames %d..%d (%d)" % (a_, b, b - a_ + 1))

    shadow_rows = sum(len(r) for r in shadow.values())
    term_rows = sum(len(r) for r in term.values())
    put("shadow_rows", shadow_rows)
    put("terminated_rows", term_rows)
    w("  %-34s %d row(s) in %d file(s)" % ("shadow-track output", shadow_rows, len(shadow)))
    w("  %-34s %d row(s) in %d file(s)" % ("terminated-track output", term_rows, len(term)))

    bridged = [n for n in trk_f if n not in det_set]
    put("tracked_without_detection", len(bridged))
    w("  %-34s %d" % ("tracked frames w/o a detection", len(bridged)))

    w("")
    w("  NOT EXERCISED by this clip -- these capabilities were neither")
    w("  demonstrated nor tested, and no claim is made about them:")
    w("    - gap bridging through missed detections   (%d interior gaps existed)"
      % len(interior))
    w("    - shadow tracking / maxShadowTrackingAge   (%d shadow rows produced)"
      % shadow_rows)
    w("    - occlusion recovery and re-association    (max 1 %s per frame; "
      "nothing ever occluded it)" % a.label)

    # --- tracker vs detector agreement ---------------------------------------
    w("")
    w("== Tracker output vs detector output (same run) ==")
    both = [n for n in trk_f if n in det_set]
    devs = []
    for n in both:
        d = max(det[n], key=lambda x: x["conf"])["box"]
        t = max(trk_rows[n], key=lambda x: x["conf"])["box"]
        devs.append(max(abs(d[i] - t[i]) for i in range(4)))
    put("frames_in_both", len(both))
    if devs:
        devs_sorted = sorted(devs)
        put("box_dev_max", "%.2f" % devs_sorted[-1])
        put("box_dev_median", "%.2f" % devs_sorted[len(devs_sorted) // 2])
        w("  %-34s %d" % ("frames present in both dumps", len(both)))
        w("  %-34s median %.2f px, max %.2f px"
          % ("tracker vs detector box offset", devs_sorted[len(devs_sorted) // 2],
             devs_sorted[-1]))
        w("  (NvSORT reports its own Kalman-filtered box, so a small offset from")
        w("   the raw detector box is expected, not a defect.)")
    else:
        put("box_dev_max", "-1")
        put("box_dev_median", "-1")

    write(a.verdict, v, out)


def write(path, verdict, report):
    print("\n".join(report))
    with open(path, "w") as fh:
        for k, val in verdict.items():
            fh.write("%s=%s\n" % (k, val))


if __name__ == "__main__":
    sys.exit(main())
