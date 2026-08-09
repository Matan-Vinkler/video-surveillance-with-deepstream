#!/usr/bin/env python3
"""analyze_zone.py - restricted-zone occupancy: measured vs independently computed.

Reads two things:

  --zone    what nvdsanalytics ACTUALLY decided, dumped by tools/analytics_probe
  --tracks  the tracker boxes, from which we RECOMPUTE the expected decision here

and reports where they agree. The recomputation is a deliberate reimplementation
of DeepStream's own arithmetic, not a call into it, so agreement is evidence
about the pipeline rather than a tautology.

Reimplemented from source, faithfully:

  nvds_analytics.cpp:600
      NvDsAnalytics_CheckObjInROI(roi_pts, curr_x, curr_y + (int)mean_h/2)
  nvds_analytics.cpp:506-507
      curr_x = left + width/2 ;  curr_y = top + height/2
  nvds_analytics.cpp:540-576
      mean_h = running mean of box height over the last m_hist frames,
      per object_id, including the current frame
  nvds_analytics.h:108-112
      the box arrives as uint32_t, so the floats are TRUNCATED first
  nvds_analytics.cpp:879
      point-in-polygon by ray cast in the -x direction, odd crossings = inside

The test point is therefore approximately the FEET, not the centroid. The
--centroid-rule output exists to make that testable rather than asserted: the
chosen ROI is placed so a centroid rule gives a completely different answer.
"""

import argparse
import glob
import os
import re
import sys

FRAME_RE = re.compile(r"_(\d+)\.txt$")
M_HIST_DEFAULT = 50  # obj-cnt-win-in-ms default; a FRAME count despite the name


def parse_roi(path):
    """Pull roi-<label>, config-width/height and class-id out of the config."""
    label, pts, cw, ch, cls = None, [], 1920, 1080, -1
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            if k.startswith("roi-"):
                label = k[4:]
                nums = [int(n) for n in v.strip(";").split(";") if n.strip()]
                pts = list(zip(nums[0::2], nums[1::2]))
            elif k == "config-width":
                cw = int(v)
            elif k == "config-height":
                ch = int(v)
            elif k == "class-id":
                cls = int(v)
    if not label or len(pts) < 3:
        raise SystemExit("could not parse an roi-<label> polygon from %s" % path)
    return label, pts, cw, ch, cls


def in_roi(pts, cgx, cgy):
    """NvDsAnalytics_CheckObjInROI, nvds_analytics.cpp:879."""
    total = 0
    frst = pts[0]
    prev = pts[0]
    for i in range(len(pts)):
        cur = pts[i + 1] if i < len(pts) - 1 else frst
        if (cgy >= prev[1] and cgy < cur[1]) or (cgy < prev[1] and cgy >= cur[1]):
            a = prev[1] - cur[1]
            b = cur[0] - prev[0]
            c = cur[1] * prev[0] - cur[0] * prev[1]
            if a != 0:
                xicp = int(-1 * (b * cgy + c) / a)   # C integer division toward zero
                if 0 <= xicp <= cgx:
                    total += 1
        prev = cur
    return total % 2 == 1


def read_tracks(path):
    """frame -> (object_id, [l, t, r, b]) from the kitti-track dump."""
    out = {}
    for f in glob.glob(os.path.join(path, "00_000_*.txt")):
        n = int(FRAME_RE.search(f).group(1))
        with open(f) as fh:
            for line in fh:
                x = line.split()
                if x:
                    out[n] = (int(x[1]), [float(v) for v in x[5:9]])
    return out


def read_zone(path):
    """frame -> {'count': n, 'meta': bool, 'objs': [(id, class, roi, rect)]}"""
    out = {}
    for f in glob.glob(os.path.join(path, "00_000_*.txt")):
        n = int(FRAME_RE.search(f).group(1))
        rec = {"count": 0, "meta": False, "objs": []}
        with open(f) as fh:
            for line in fh:
                x = line.split()
                if not x:
                    continue
                if x[0] == "frame":
                    if x[2] != "NOMETA":
                        rec["meta"] = True
                        rec["count"] = int(x[3])
                elif x[0] == "obj":
                    rec["objs"].append({
                        "id": int(x[1]), "class": int(x[2]), "label": x[3],
                        "det": [float(v) for v in x[4:8]],
                        "trk": [float(v) for v in x[8:12]],
                        "rect": [float(v) for v in x[12:16]],
                        "roi": x[18],
                    })
        out[n] = rec
    return out


def expected(tracks, pts, m_hist, use_centroid=False):
    """Recompute the ROI verdict per frame from the tracker boxes."""
    hist = {}
    out = {}
    for n in sorted(tracks):
        oid, (L, T, R, B) = tracks[n]
        left, top = int(L), int(T)
        w, h = int(R - L), int(B - T)
        st = hist.setdefault(oid, {"p": [0] * m_hist, "i": 0, "c": 0, "s": 0})
        i = st["i"]
        if st["c"] >= m_hist:
            st["s"] -= st["p"][i]
        st["p"][i] = h
        st["i"] = (i + 1) % m_hist
        st["s"] += h
        frm_win = m_hist if st["c"] >= m_hist else st["c"] + 1
        mean_h = st["s"] / frm_win
        st["c"] += 1
        cx = left + w // 2
        cy = top + h // 2
        ty = cy if use_centroid else cy + int(mean_h) // 2
        out[n] = (in_roi(pts, cx, ty), cx, ty)
    return out


def runs(frames):
    """[(start, end)] for maximal consecutive stretches."""
    out, start, prev = [], None, None
    for n in frames:
        if start is None:
            start = prev = n
        elif n == prev + 1:
            prev = n
        else:
            out.append((start, prev))
            start = prev = n
    if start is not None:
        out.append((start, prev))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--zone", required=True)
    ap.add_argument("--tracks", required=True)
    ap.add_argument("--config", required=True)
    ap.add_argument("--verdict", required=True)
    ap.add_argument("--m-hist", type=int, default=M_HIST_DEFAULT)
    ap.add_argument("--fps", type=float, default=29.97)
    a = ap.parse_args()

    label, pts, cw, ch, cls = parse_roi(a.config)
    zone = read_zone(a.zone)
    tracks = read_tracks(a.tracks)

    v, out = {}, []
    w = out.append

    w("== Restricted zone ==")
    w("  %-32s %s" % ("ROI label", label))
    w("  %-32s %s" % ("polygon", " ".join("(%d,%d)" % p for p in pts)))
    w("  %-32s %dx%d" % ("reference resolution", cw, ch))
    w("  %-32s class-id=%d" % ("class filter", cls))
    v["roi_label"] = label
    v["class_id"] = cls

    v["zone_files"] = len(zone)
    v["frames_with_analytics_meta"] = sum(1 for r in zone.values() if r["meta"])

    # ---- what DeepStream decided -------------------------------------------
    ds_in = sorted(n for n, r in zone.items() if r["count"] > 0)
    obj_in = sorted(n for n, r in zone.items()
                    if any(o["roi"] != "-" for o in r["objs"]))
    v["ds_frames_inside"] = len(ds_in)
    v["obj_roistatus_frames"] = len(obj_in)
    v["frame_obj_agree"] = int(ds_in == obj_in)

    w("")
    w("== What nvdsanalytics decided (measured) ==")
    w("  %-32s %d" % ("frames written by the probe", len(zone)))
    w("  %-32s %d" % ("frames with analytics frame meta", v["frames_with_analytics_meta"]))
    if ds_in:
        rr = runs(ds_in)
        v["ds_entry"] = ds_in[0]
        v["ds_exit"] = ds_in[-1]
        v["ds_runs"] = len(rr)
        v["ds_longest_run"] = max(b - a_ + 1 for a_, b in rr)
        w("  %-32s %d" % ("frames with objInROIcnt > 0", len(ds_in)))
        w("  %-32s %d" % ("entry frame", ds_in[0]))
        w("  %-32s %d" % ("exit frame (last inside)", ds_in[-1]))
        w("  %-32s %d" % ("contiguous runs", len(rr)))
        for a_, b in rr:
            w("      frames %d..%d  (%d frames, %.2f s)"
              % (a_, b, b - a_ + 1, (b - a_ + 1) / a.fps))
        w("  %-32s %s" % ("per-object roiStatus agrees",
                          "yes" if ds_in == obj_in else "NO"))
    else:
        for k in ("ds_entry", "ds_exit", "ds_longest_run"):
            v[k] = -1
        v["ds_runs"] = 0
        w("  %-32s %s" % ("frames with objInROIcnt > 0", "0  (nobody ever inside)"))

    # ---- what the geometry says --------------------------------------------
    exp = expected(tracks, pts, a.m_hist)
    exp_in = sorted(n for n, (s, _, _) in exp.items() if s)
    cen = expected(tracks, pts, a.m_hist, use_centroid=True)
    cen_in = sorted(n for n, (s, _, _) in cen.items() if s)
    v["expected_frames_inside"] = len(exp_in)
    v["centroid_rule_frames_inside"] = len(cen_in)
    v["expected_entry"] = exp_in[0] if exp_in else -1
    v["expected_exit"] = exp_in[-1] if exp_in else -1

    w("")
    w("== Independently recomputed from the tracker boxes ==")
    w("  %-32s %d frames" % ("foot rule (what DeepStream uses)", len(exp_in)))
    if exp_in:
        w("      entry %d, exit %d, %d run(s)"
          % (exp_in[0], exp_in[-1], len(runs(exp_in))))
    w("  %-32s %d frames" % ("centroid rule (counterfactual)", len(cen_in)))

    # ---- agreement ----------------------------------------------------------
    common = sorted(set(zone) & set(tracks))
    disagree = []
    for n in common:
        ds = zone[n]["count"] > 0
        ex, cx, ty = exp[n]
        if ds != ex:
            disagree.append((n, ds, ex, cx, ty))
    # frames the tracker saw nobody are trivially "outside" in both
    v["compared_frames"] = len(common)
    v["disagreements"] = len(disagree)
    v["agreement_pct"] = ("%.2f" % (100.0 * (len(common) - len(disagree)) / len(common))
                          if common else "0.00")

    w("")
    w("== Measured vs recomputed ==")
    w("  %-32s %d" % ("frames compared", len(common)))
    w("  %-32s %d" % ("disagreements", len(disagree)))
    w("  %-32s %s%%" % ("agreement", v["agreement_pct"]))
    for n, ds, ex, cx, ty in disagree[:20]:
        w("      frame %d: DeepStream=%s recomputed=%s  test point (%d,%d)"
          % (n, "in" if ds else "out", "in" if ex else "out", cx, ty))

    # ---- which box analytics consumed --------------------------------------
    # rect_params is the tracker's CLIPPED box; the kitti-track dump records the
    # UNCLIPPED one. On this clip nothing is clipped, so they should coincide --
    # measured rather than assumed.
    devs = []
    for n in common:
        for o in zone[n]["objs"]:
            if o["id"] == tracks[n][0]:
                devs.append(max(abs(o["rect"][i] - o["trk"][i]) for i in range(4)))
    v["rect_vs_trk_max_dev"] = "%.2f" % (max(devs) if devs else -1)
    w("")
    w("  %-32s %.2f px" % ("max |rect_params - tracker bbox|",
                           max(devs) if devs else -1))

    # ---- class filter -------------------------------------------------------
    classes = sorted({o["class"] for r in zone.values() for o in r["objs"]
                      if o["roi"] != "-"})
    v["roi_classes"] = ",".join(str(c) for c in classes) if classes else "-"
    w("  %-32s %s" % ("class ids ever flagged in ROI", v["roi_classes"] or "(none)"))

    print("\n".join(out))
    with open(a.verdict, "w") as fh:
        for k, val in v.items():
            fh.write("%s=%s\n" % (k, val))


if __name__ == "__main__":
    sys.exit(main())
