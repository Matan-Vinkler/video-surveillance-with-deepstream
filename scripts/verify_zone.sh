#!/usr/bin/env bash
# verify_zone.sh - headless, machine-checked verification of the Milestone 5
# checkpoint-3 restricted zone:
#
#   ... -> nvinfer -> nvtracker (NvSORT) -> nvdsanalytics -> tiler -> osd -> sink
#
# Needs no display, terminates on its own, never loops.
#
# deepstream-app can RUN nvdsanalytics but cannot REPORT it: its source never
# reads NVDS_USER_{OBJ,FRAME}_META_NVDSANALYTICS, so the ROI verdict reaches no
# dump, no log and no message payload. tools/analytics_probe.cpp is built to
# read it back, and is CROSS-CHECKED against deepstream-app rather than trusted:
# if its detector and tracker output do not match deepstream-app's own KITTI
# dumps frame for frame, the two are not running the same pipeline and the
# analytics evidence is void.
#
# Five runs:
#   RUN 1  deepstream-app, analytics ENABLED   -> detector + tracker dumps
#   RUN 2  deepstream-app, analytics DISABLED  -> control; proves analytics
#          changed neither detection nor tracking
#   RUN 3  analytics_probe, same configs       -> the ROI verdict
#   RUN 4  analytics_probe, class-id=0 (car)   -> proves class-id controls the rule
#   RUN 5  deepstream-app, bogus analytics config -> must FAIL
#
# What it proves:
#   1  the application runs to a clean EOS with nvdsanalytics instantiated
#   2  detection and tracking are UNCHANGED by adding analytics
#   3  the probe runs the same pipeline (per-frame box agreement)
#   4  analytics metadata exists in machine-readable form
#   5  the person is OUTSIDE the zone before entering
#   6  the person ENTERS at the predicted frame
#   7  the person REMAINS inside for a measurable contiguous run
#   8  the person EXITS, and stays visible afterwards
#   9  DeepStream's verdict matches an independent recomputation
#  10  class-id=2 really is what restricts the rule
#  11  the ROI test point is the FEET, not the centroid
#  12  a broken analytics config fails loudly
#  13  nothing beyond the approved scope
#  14  checkpoint 2, checkpoint 1 and Milestone 2 regressions still pass
#
# Usage:
#   ./scripts/verify_zone.sh

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ds_common.sh"

# Expected behaviour, derived in docs/milestone-05-restricted-zone.md from the
# measured track. Entry and exit carry a +/-2 frame tolerance because the
# subject advances 8-12 px per frame against an 8 px boundary margin.
EXPECT_ENTRY=109
EXPECT_EXIT=183
FRAME_TOL=2
MIN_DWELL=70
MIN_VISIBLE_AFTER=80

while (( $# > 0 )); do
    case "$1" in
        -h|--help) sed -n '2,47p' "$0"; exit 0 ;;
        *) die "Unknown option '$1'. Try --help." ;;
    esac
done

require_tools
require_deepstream_app
require_elements nvstreammux nvinfer nvtracker nvdsanalytics \
                 nvmultistreamtiler nvvideoconvert nvdsosd fakesink
require_tracker_assets
require_analytics_config
require_probe

APP_CFG="$(require_config deepstream_app_walk_headless.txt)"
INFER_CFG="$(require_config config_infer_primary_trafficcamnet.txt)"
ZONE_CFG="$(analytics_config)"
ANALYZER="$REPO_ROOT/scripts/analyze_zone.py"
TRACK_ANALYZER="$REPO_ROOT/scripts/analyze_tracks.py"
[[ -r "$ANALYZER" && -r "$TRACK_ANALYZER" ]] || die "Analyzer scripts not found."

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

FAILURES=0
note_pass() { printf '  PASS  %s\n' "$*"; }
note_fail() { printf '  FAIL  %s\n' "$*"; FAILURES=$(( FAILURES + 1 )); }

# Rewrite the app config into $WORKDIR: relative paths must be absolved, since
# deepstream-app resolves them against the config file's own directory.
make_variant() {   # make_variant <sed-expr> <out> [extra-sed...]
    local expr="$1" out="$2"; shift 2
    sed "$expr" "$APP_CFG" > "$out"
    sed -i -e "s|^config-file=config_|config-file=$CONFIG_DIR/config_|" "$out"
    local e
    for e in "$@"; do sed -i -e "$e" "$out"; done
}

# ------------------------------------------------------------- environment ---
bold "== Environment =="
printf '  %-28s %s\n' "DeepStream" "$(ds_version)"
printf '  %-28s %s\n' "GPU" "$(gpu_slug)"
printf '  %-28s %s\n' "analytics config" "$ZONE_CFG"
printf '  %-28s %s\n' "ROI" "$(sed -n 's/^roi-RF=//p' "$ZONE_CFG")"
printf '  %-28s %s\n' "probe" "$PROBE_BIN"
ENGINE_TARGET="$(ensure_engine_link)"
printf '  %-28s %s\n' "engine" "$(basename "$ENGINE_TARGET")"
FINGERPRINT_BEFORE="$(engine_fingerprint)"

for d in "$DETECTION_DIR" "$TRACK_DIR" "$TERMINATED_DIR" "$SHADOW_DIR" "$ZONE_DIR"; do
    rm -rf "$d"; mkdir -p "$d"
done

# ------------------------------------------------------------------ run 1 ----
bold "== RUN 1: deepstream-app with the restricted zone enabled =="
RUN_LOG="$WORKDIR/run1.log"
rc=0
GST_DEBUG=GST_ELEMENT_FACTORY:4 deepstream-app -c "$APP_CFG" >"$RUN_LOG" 2>&1 || rc=$?
printf '  %-28s %s\n' "exit status" "$rc"
FINGERPRINT_AFTER="$(engine_fingerprint)"

bold "== CHECK 1: the application runs, with nvdsanalytics instantiated =="
if (( rc == 0 )); then
    note_pass "deepstream-app exited 0"
else
    tail -n 25 "$RUN_LOG" >&2
    note_fail "deepstream-app exited $rc"
fi
if grep -qE 'ERROR from element|Error\(s\) in config file|App run failed' "$RUN_LOG"; then
    grep -E 'ERROR from element|Error\(s\) in config file|App run failed' "$RUN_LOG" | head -5 >&2
    note_fail "the log reports a pipeline error"
else
    note_pass "no pipeline errors in the log"
fi
if grep -q 'creating element "nvdsanalytics"' "$RUN_LOG"; then
    note_pass "GStreamer created an nvdsanalytics element"
else
    note_fail "no nvdsanalytics element was created"
fi
if grep -qiE 'nvdsanalytics.*(Failed|ERROR)' "$RUN_LOG"; then
    grep -inE 'nvdsanalytics.*(Failed|ERROR)' "$RUN_LOG" | head -3 >&2
    note_fail "nvdsanalytics reported a configuration error"
else
    note_pass "nvdsanalytics parsed its configuration without error"
fi
if [[ "$FINGERPRINT_BEFORE" == "$FINGERPRINT_AFTER" ]]; then
    note_pass "the FP16 engine was not rebuilt or modified"
else
    note_fail "the engine file changed during the run"
fi

cp -r "$DETECTION_DIR" "$WORKDIR/det_analytics"
cp -r "$TRACK_DIR"     "$WORKDIR/trk_analytics"

# ------------------------------------------------------------------ run 2 ----
bold "== RUN 2: same pipeline, analytics DISABLED (control) =="
CTRL_DET="$WORKDIR/det_control"; CTRL_TRK="$WORKDIR/trk_control"
mkdir -p "$CTRL_DET" "$CTRL_TRK"
# Set enable=0 inside [nvds-analytics] only, and redirect the dumps.
awk '
    /^\[/ { in_an = ($0 == "[nvds-analytics]") }
    in_an && /^enable=/ { print "enable=0"; next }
                        { print }
' "$APP_CFG" > "$WORKDIR/app_no_analytics.txt"
sed -i -e "s|^config-file=config_|config-file=$CONFIG_DIR/config_|" \
       -e "s|^gie-kitti-output-dir=.*|gie-kitti-output-dir=$CTRL_DET|" \
       -e "s|^kitti-track-output-dir=.*|kitti-track-output-dir=$CTRL_TRK|" \
       -e "/^terminated-track-output-dir=/d" -e "/^shadow-track-output-dir=/d" \
       "$WORKDIR/app_no_analytics.txt"
ctrl_rc=0
GST_DEBUG=GST_ELEMENT_FACTORY:4 deepstream-app -c "$WORKDIR/app_no_analytics.txt" \
    >"$WORKDIR/run2.log" 2>&1 || ctrl_rc=$?
printf '  %-28s %s\n' "exit status" "$ctrl_rc"

bold "== CHECK 2: analytics changed neither detection nor tracking =="
if (( ctrl_rc != 0 )); then
    tail -n 15 "$WORKDIR/run2.log" >&2
    note_fail "the analytics-disabled control run exited $ctrl_rc"
elif grep -q 'creating element "nvdsanalytics"' "$WORKDIR/run2.log"; then
    note_fail "the control run still created an nvdsanalytics element"
else
    note_pass "control run has no nvdsanalytics element"
fi
DET_DIFF="$(diff -rq "$WORKDIR/det_analytics" "$CTRL_DET" 2>/dev/null | wc -l)"
TRK_DIFF="$(diff -rq "$WORKDIR/trk_analytics" "$CTRL_TRK" 2>/dev/null | wc -l)"
printf '  %-28s %s\n' "detector frames differing" "$DET_DIFF"
printf '  %-28s %s\n' "tracker frames differing" "$TRK_DIFF"
# Checkpoint 1 measured ~1% run-to-run detection jitter; a change caused by
# analytics would be structural, not a couple of frames.
if (( DET_DIFF <= 5 )); then
    note_pass "detector output is materially identical with and without analytics ($DET_DIFF frames differ)"
else
    diff -rq "$WORKDIR/det_analytics" "$CTRL_DET" | head -5 >&2
    note_fail "$DET_DIFF detector frames differ -- more than run-to-run jitter explains"
fi
if (( TRK_DIFF <= 5 )); then
    note_pass "tracker output is materially identical with and without analytics ($TRK_DIFF frames differ)"
else
    diff -rq "$WORKDIR/trk_analytics" "$CTRL_TRK" | head -5 >&2
    note_fail "$TRK_DIFF tracker frames differ -- analytics perturbed tracking"
fi

# ------------------------------------------------------------------ run 3 ----
bold "== RUN 3: analytics_probe, reading the ROI verdict back =="
probe_rc=0
"$PROBE_BIN" \
    --video "$(resolve_video)" \
    --infer-config "$INFER_CFG" \
    --tracker-lib "$(tracker_lib)" \
    --tracker-config "$(tracker_config)" \
    --analytics-config "$ZONE_CFG" \
    --out-dir "$ZONE_DIR" >"$WORKDIR/probe.log" 2>&1 || probe_rc=$?
printf '  %-28s %s\n' "exit status" "$probe_rc"
grep -m1 '^frames written' "$WORKDIR/probe.log" | sed 's/^/  /' || true

bold "== CHECK 3: the probe ran the SAME pipeline as the application =="
if (( probe_rc == 0 )); then
    note_pass "analytics_probe exited 0"
else
    tail -n 20 "$WORKDIR/probe.log" >&2
    note_fail "analytics_probe exited $probe_rc"
fi
# Only the analytics files; the probe also writes pgie_* pre-tracker records.
ZONE_FILES="$(find "$ZONE_DIR" -name '00_000_*.txt' -type f | wc -l)"
EXPECTED_FRAMES="$(video_frame_count "$(resolve_video)")"
printf '  %-28s %s of %s\n' "frames written" "$ZONE_FILES" "$EXPECTED_FRAMES"
if (( ZONE_FILES == EXPECTED_FRAMES )); then
    note_pass "the probe saw every frame of the clip"
else
    note_fail "the probe wrote $ZONE_FILES files but the clip holds $EXPECTED_FRAMES"
fi

# The cross-check that makes the probe's evidence admissible.
XCHECK="$WORKDIR/xcheck.txt"
ZONE_DIR="$ZONE_DIR" DET_DIR="$WORKDIR/det_analytics" TRK_DIR="$WORKDIR/trk_analytics" \
python3 - >"$XCHECK" <<'PY'
import glob, os, re
FR = re.compile(r"_(\d+)\.txt$")
def load(d, box_at, id_at=None):
    out = {}
    for f in glob.glob(os.path.join(d, "00_000_*.txt")):
        n = int(FR.search(f).group(1))
        rows = []
        for line in open(f):
            x = line.split()
            if x:
                rows.append((int(x[id_at]) if id_at is not None else None,
                             [float(v) for v in x[box_at:box_at + 4]]))
        out[n] = rows
    return out
det = load(os.environ["DET_DIR"], 4)          # detector dump: label l t r b ...
trk = load(os.environ["TRK_DIR"], 5, 1)       # track dump:    label id l t r b ...

# The probe records BOTH sides: pgie_* from a probe on nvinfer's src pad
# (pre-tracker) and 00_000_* from the analytics src pad (post-tracker). They
# must be compared against the matching deepstream-app dump -- comparing
# post-tracker objects against a pre-tracker dump would flag the tracker's own
# legitimate object removals as a pipeline difference.
zone = {}
for f in glob.glob(os.path.join(os.environ["ZONE_DIR"], "00_000_*.txt")):
    n = int(FR.search(f).group(1))
    rows = []
    for line in open(f):
        x = line.split()
        if x and x[0] == "obj":
            rows.append({"id": int(x[1]),
                         "trk": [float(v) for v in x[8:12]]})
    zone[n] = rows

pgie = {}
for f in glob.glob(os.path.join(os.environ["ZONE_DIR"], "pgie_00_000_*.txt")):
    n = int(FR.search(f).group(1))
    pgie[n] = [[float(v) for v in l.split()[3:7]] for l in open(f) if l.split()]

dmax = tmax = 0.0
dcount = 0
common_d = sorted(set(det) & set(pgie))
for n in common_d:
    if len(pgie[n]) != len(det[n]):
        dcount += 1
    for a, b in zip(sorted(pgie[n]), sorted(det[n], key=lambda r: r[1])):
        dmax = max(dmax, max(abs(a[i] - b[1][i]) for i in range(4)))

# Post-tracker: report WHICH frames diverge rather than counting them, so the
# caller can require the divergence to lie outside the ROI interval instead of
# accepting an unexplained tolerance.
bad = []
common_t = sorted(set(trk) & set(zone))
for n in common_t:
    if len(zone[n]) != len(trk[n]):
        bad.append(n)
        continue
    for a, b in zip(sorted(zone[n], key=lambda r: r["trk"][0]),
                    sorted(trk[n], key=lambda r: r[1][0])):
        dev = max(abs(a["trk"][i] - b[1][i]) for i in range(4))
        if a["id"] != b[0] or dev >= 0.01:
            bad.append(n)
            break
        tmax = max(tmax, dev)
print("det_compared=%d" % len(common_d))
print("trk_compared=%d" % len(common_t))
print("det_count_mismatch=%d" % dcount)
print("det_max_dev=%.4f" % dmax)
print("trk_max_dev=%.4f" % tmax)
print("trk_diverging=%d" % len(bad))
print("trk_diverging_max_frame=%d" % (max(bad) if bad else -1))
print("trk_diverging_frames=%s" % (",".join(str(n) for n in bad) if bad else "-"))
PY
xget() { sed -n "s/^$1=//p" "$XCHECK"; }
printf '  %-28s %s\n' "detector frames compared" "$(xget det_compared)"
printf '  %-28s %s, max dev %s px\n' "detector mismatches" \
    "$(xget det_count_mismatch)" "$(xget det_max_dev)"
printf '  %-28s %s (max frame %s)\n' "post-tracker diverging frames" \
    "$(xget trk_diverging)" "$(xget trk_diverging_max_frame)"
printf '  %-28s %s\n' "diverging frames" "$(xget trk_diverging_frames)"

# The DETECTOR must match exactly. Both runs load the same engine from the same
# config, so anything but bit-identical output means they are not the same
# pipeline, and no tolerance could be justified.
if [[ "$(xget det_count_mismatch)" == "0" ]] \
   && awk -v d="$(xget det_max_dev)" 'BEGIN { exit !(d < 0.01) }'; then
    note_pass "detector output is bit-identical on all $(xget det_compared) frames"
else
    note_fail "the probe's detector output differs from deepstream-app's -- not the same pipeline"
fi

# The POST-TRACKER comparison has a known, bounded divergence: the low-level
# tracker claims a new target immediately under deepstream-app but only after
# its probation window here, so objects differ on the first few frames of each
# track. That is stated as a bound rather than absorbed into a tolerance -- the
# divergence must end long before the ROI is reached, or the ROI evidence is
# not admissible. Mechanism unproven; see docs/milestone-05-restricted-zone.md
DIVERGE_MAX="$(xget trk_diverging_max_frame)"
DIVERGE_LIMIT=$(( EXPECT_ENTRY - 20 ))
if (( DIVERGE_MAX < DIVERGE_LIMIT )); then
    note_pass "post-tracker divergence ends at frame $DIVERGE_MAX, more than 20 frames before the zone is entered at $EXPECT_ENTRY"
else
    note_fail "post-tracker divergence reaches frame $DIVERGE_MAX, too close to the ROI interval to trust the analytics evidence"
fi

# ------------------------------------------------------------- measurement ---
bold "== Measured restricted-zone behaviour =="
VERDICT="$WORKDIR/zone_verdict.txt"
python3 "$ANALYZER" --zone "$ZONE_DIR" --tracks "$WORKDIR/trk_analytics" \
    --config "$ZONE_CFG" --verdict "$VERDICT"
get() { sed -n "s/^$1=//p" "$VERDICT"; }

# --- 4. metadata present ---
bold "== CHECK 4: analytics metadata is present and machine-readable =="
META_FRAMES="$(get frames_with_analytics_meta)"
printf '  %-28s %s of %s\n' "frames with frame meta" "$META_FRAMES" "$ZONE_FILES"
if (( META_FRAMES == ZONE_FILES )); then
    note_pass "every frame carries NvDsAnalyticsFrameMeta"
else
    note_fail "only $META_FRAMES of $ZONE_FILES frames carry analytics frame meta"
fi
if [[ "$(get frame_obj_agree)" == "1" ]]; then
    note_pass "per-object roiStatus agrees with the frame-level count on every frame"
else
    note_fail "per-object roiStatus and frame-level objInROIcnt disagree"
fi

DS_ENTRY="$(get ds_entry)"; DS_EXIT="$(get ds_exit)"
DS_INSIDE="$(get ds_frames_inside)"; DS_RUNS="$(get ds_runs)"

# --- 5. outside before ---
bold "== CHECK 5: the person is OUTSIDE the zone before entering =="
if (( DS_ENTRY > 0 )); then
    note_pass "no ROI occupancy on any frame before $DS_ENTRY"
else
    note_fail "the zone was occupied from the very first frame, or never"
fi

# --- 6. enters ---
bold "== CHECK 6: the person ENTERS the zone =="
printf '  %-28s %s (expected %s +/- %s)\n' "entry frame" "$DS_ENTRY" "$EXPECT_ENTRY" "$FRAME_TOL"
if (( DS_ENTRY >= EXPECT_ENTRY - FRAME_TOL && DS_ENTRY <= EXPECT_ENTRY + FRAME_TOL )); then
    note_pass "entry at frame $DS_ENTRY, within +/-$FRAME_TOL of the predicted $EXPECT_ENTRY"
else
    note_fail "entry at frame $DS_ENTRY, outside +/-$FRAME_TOL of the predicted $EXPECT_ENTRY"
fi

# --- 7. remains inside ---
bold "== CHECK 7: the person REMAINS inside for a measurable interval =="
printf '  %-28s %s\n' "frames inside" "$DS_INSIDE"
printf '  %-28s %s\n' "contiguous runs" "$DS_RUNS"
printf '  %-28s %s\n' "longest run" "$(get ds_longest_run) frames"
if (( DS_INSIDE >= MIN_DWELL )); then
    note_pass "$DS_INSIDE frames inside (>= $MIN_DWELL)"
else
    note_fail "only $DS_INSIDE frames inside (< $MIN_DWELL)"
fi
if (( DS_RUNS == 1 )); then
    note_pass "occupancy is a single unbroken interval"
else
    note_fail "occupancy is split across $DS_RUNS intervals"
fi

# --- 8. exits, and stays visible ---
bold "== CHECK 8: the person EXITS and remains visible afterwards =="
# Highest frame number whose track file is non-empty. 10# forces base 10:
# the frame numbers are zero-padded, and bash would otherwise read 099 as octal.
LAST_TRACKED="$(find "$WORKDIR/trk_analytics" -name '00_000_*.txt' -size +0c -printf '%f\n' \
                 | sed -n 's/^00_000_0*\([0-9][0-9]*\)\.txt$/\1/p' | sort -n | tail -1)"
[[ -n "$LAST_TRACKED" ]] || die "No non-empty track file found; cannot measure visibility after exit."
VISIBLE_AFTER=$(( 10#$LAST_TRACKED - DS_EXIT ))
printf '  %-28s %s (expected %s +/- %s)\n' "exit frame (last inside)" "$DS_EXIT" "$EXPECT_EXIT" "$FRAME_TOL"
printf '  %-28s %s\n' "last tracked frame" "$LAST_TRACKED"
printf '  %-28s %s\n' "frames visible after exit" "$VISIBLE_AFTER"
if (( DS_EXIT >= EXPECT_EXIT - FRAME_TOL && DS_EXIT <= EXPECT_EXIT + FRAME_TOL )); then
    note_pass "exit after frame $DS_EXIT, within +/-$FRAME_TOL of the predicted $EXPECT_EXIT"
else
    note_fail "exit after frame $DS_EXIT, outside +/-$FRAME_TOL of the predicted $EXPECT_EXIT"
fi
if (( VISIBLE_AFTER >= MIN_VISIBLE_AFTER )); then
    note_pass "the person stays tracked for $VISIBLE_AFTER frames after leaving the zone"
else
    note_fail "only $VISIBLE_AFTER tracked frames after the exit (< $MIN_VISIBLE_AFTER)"
fi

# --- 9. agreement with an independent recomputation ---
bold "== CHECK 9: DeepStream's verdict vs an independent recomputation =="
printf '  %-28s %s\n' "frames compared" "$(get compared_frames)"
printf '  %-28s %s\n' "disagreements" "$(get disagreements)"
printf '  %-28s %s%%\n' "agreement" "$(get agreement_pct)"
if awk -v p="$(get agreement_pct)" 'BEGIN { exit !(p >= 99.0) }'; then
    note_pass "$(get agreement_pct)% agreement with the recomputed foot-point rule"
else
    note_fail "only $(get agreement_pct)% agreement -- the model of DeepStream's rule is wrong, or the pipeline is"
fi

# --- 10. class filter ---
bold "== CHECK 10: class-id=2 is what restricts the rule =="
CLASSES="$(get roi_classes)"
printf '  %-28s %s\n' "class ids flagged in ROI" "$CLASSES"
if [[ "$CLASSES" == "2" ]]; then
    note_pass "only class 2 (person) was ever flagged inside the zone"
else
    note_fail "classes '$CLASSES' were flagged inside a person-only zone"
fi
# The experiment: same ROI, same clip, class-id=0 (car). Nothing may be flagged.
CAR_CFG="$WORKDIR/zone_car.txt"
sed 's/^class-id=2/class-id=0/' "$ZONE_CFG" > "$CAR_CFG"
CAR_DIR="$WORKDIR/zone_car"; mkdir -p "$CAR_DIR"
car_rc=0
"$PROBE_BIN" --video "$(resolve_video)" --infer-config "$INFER_CFG" \
    --tracker-lib "$(tracker_lib)" --tracker-config "$(tracker_config)" \
    --analytics-config "$CAR_CFG" --out-dir "$CAR_DIR" \
    >"$WORKDIR/probe_car.log" 2>&1 || car_rc=$?
CAR_INSIDE="$(grep -h '^frame ' "$CAR_DIR"/*.txt | awk '$4 > 0' | wc -l)"
CAR_ROI="$(grep -h '^obj ' "$CAR_DIR"/*.txt | awk '$19 != "-"' | wc -l)"
printf '  %-28s %s\n' "class-id=0 run exit status" "$car_rc"
printf '  %-28s %s\n' "frames with occupancy > 0" "$CAR_INSIDE"
printf '  %-28s %s\n' "objects flagged in ROI" "$CAR_ROI"
if (( car_rc == 0 && CAR_INSIDE == 0 && CAR_ROI == 0 )); then
    note_pass "with class-id=0 the identical ROI reports zero occupancy: the class filter, not the geometry, is what selects the person"
else
    note_fail "class-id=0 still produced occupancy ($CAR_INSIDE frames, $CAR_ROI objects)"
fi

# --- 11. the reference point ---
bold "== CHECK 11: the ROI test point is the FEET, not the centroid =="
FOOT="$(get expected_frames_inside)"; CENTROID="$(get centroid_rule_frames_inside)"
printf '  %-28s %s frames\n' "foot rule" "$FOOT"
printf '  %-28s %s frames\n' "centroid rule" "$CENTROID"
printf '  %-28s %s frames\n' "DeepStream measured" "$DS_INSIDE"
if (( CENTROID == 0 && FOOT > 0 )) \
   && (( DS_INSIDE >= FOOT - FRAME_TOL && DS_INSIDE <= FOOT + FRAME_TOL )); then
    note_pass "the same ROI gives $FOOT frames under the foot rule and $CENTROID under a centroid rule; DeepStream reports $DS_INSIDE -- the implementation uses the feet"
else
    note_fail "the foot/centroid experiment did not discriminate (foot=$FOOT centroid=$CENTROID deepstream=$DS_INSIDE)"
fi

# --- 12. negative control ---
bold "== CHECK 12: a broken analytics config must fail the run =="
make_variant "s|^config-file=config_nvdsanalytics_restricted_zone.txt|config-file=/nonexistent/config_zone_NOPE.txt|" \
    "$WORKDIR/app_bad_zone.txt" \
    "/^gie-kitti-output-dir=/d" "/^kitti-track-output-dir=/d" \
    "/^terminated-track-output-dir=/d" "/^shadow-track-output-dir=/d"
bad_rc=0
deepstream-app -c "$WORKDIR/app_bad_zone.txt" >"$WORKDIR/run5.log" 2>&1 || bad_rc=$?
printf '  %-28s %s\n' "exit status" "$bad_rc"
if (( bad_rc != 0 )) && grep -q 'Configuration file parsing failed' "$WORKDIR/run5.log"; then
    note_pass "a nonexistent analytics config fails the run (exit $bad_rc)"
    grep -m1 'Failed to parse config file' "$WORKDIR/run5.log" | sed 's/^/    /'
else
    tail -n 10 "$WORKDIR/run5.log" >&2
    note_fail "the app did not fail with a nonexistent analytics config (exit $bad_rc)"
fi

# --- 13. scope ---
bold "== CHECK 13: nothing beyond the approved scope =="
OUT_OF_SCOPE='^\[secondary-gie|^\[line-crossing|^\[overcrowding|^\[direction-detection|^\[message-broker|^\[message-converter'
if grep -rqE "$OUT_OF_SCOPE" "$CONFIG_DIR"/; then
    grep -rnE "$OUT_OF_SCOPE" "$CONFIG_DIR"/ >&2
    note_fail "out-of-scope configuration is present"
else
    note_pass "ROI filtering only -- no line crossing, overcrowding, direction or messaging"
fi

# --- 14. regressions ---
bold "== CHECK 14: earlier checkpoints still pass =="
# Tracking first: analytics moves the track-dump probe onto the analytics src
# pad, so identity must be re-measured, not assumed.
TRK_VERDICT="$WORKDIR/track_verdict.txt"
python3 "$TRACK_ANALYZER" --detections "$WORKDIR/det_analytics" \
    --tracks "$WORKDIR/trk_analytics" --terminated "$TERMINATED_DIR" \
    --shadow "$SHADOW_DIR" --verdict "$TRK_VERDICT" >"$WORKDIR/track_report.txt"
tget() { sed -n "s/^$1=//p" "$TRK_VERDICT"; }
printf '  %-28s %s\n' "mid-track ID switches" "$(tget mid_track_switches)"
printf '  %-28s %s\n' "unique track ids" "$(tget unique_ids)"
printf '  %-28s %s frames\n' "longest continuous track" "$(tget longest_run_len)"
if [[ "$(tget mid_track_switches)" == "0" ]]; then
    note_pass "no new ID switches were introduced by analytics"
else
    note_fail "$(tget mid_track_switches) mid-track ID switch(es) appeared"
fi

for suite in verify_tracking.sh verify_inference.sh verify_simulated_stream.sh; do
    suite_rc=0
    "$REPO_ROOT/scripts/$suite" >"$WORKDIR/$suite.log" 2>&1 || suite_rc=$?
    if (( suite_rc == 0 )); then
        note_pass "$suite exited 0"
    else
        tail -n 20 "$WORKDIR/$suite.log" >&2
        note_fail "$suite exited $suite_rc"
    fi
done

# ---------------------------------------------------------------- summary ----
bold "== Summary =="
printf '  %-28s %s\n' "frames processed" "$ZONE_FILES"
printf '  %-28s %s\n' "entry frame" "$DS_ENTRY"
printf '  %-28s %s\n' "exit frame" "$DS_EXIT"
printf '  %-28s %s frames (%s)\n' "time inside the zone" "$DS_INSIDE" \
    "$(awk -v f="$DS_INSIDE" 'BEGIN { printf "%.2f s", f / 29.97 }')"
printf '  %-28s %s\n' "contiguous runs" "$DS_RUNS"
printf '  %-28s %s%%\n' "agreement with recomputation" "$(get agreement_pct)"
printf '  %-28s %s\n' "zone evidence kept" "$ZONE_DIR"

if (( FAILURES == 0 )); then
    bold "All checks passed."
    exit 0
fi
die "$FAILURES check(s) failed."
