/*
 * analytics_probe.cpp - read nvdsanalytics metadata back out of a DeepStream
 *                       pipeline, one file per frame.
 *
 * WHY THIS EXISTS
 * ---------------
 * `deepstream-app` can RUN nvdsanalytics but cannot REPORT it. Its source never
 * reads NVDS_USER_OBJ_META_NVDSANALYTICS or NVDS_USER_FRAME_META_NVDSANALYTICS,
 * so the ROI verdict reaches no KITTI dump, no log and no message payload
 * (nvmsgconv does not carry it either). The shipped
 * deepstream-nvdsanalytics-test does print it, but hard-codes NvDCF and
 * nv3dsink -- it would change the tracker backend and require a display.
 *
 * WHAT THIS IS, AND IS NOT
 * ------------------------
 * This is TEST EQUIPMENT, not the application. `deepstream-app` driven by the
 * .txt configs in configs/ remains the surveillance application. This program
 * builds the same pipeline from the SAME configuration files, attaches ONE pad
 * probe on the nvdsanalytics source pad, and writes what it finds.
 *
 * It is not trusted on its own: verify_zone.sh cross-checks its detector and
 * tracker output against deepstream-app's own KITTI dumps frame for frame. If
 * they disagree, the two are not running the same pipeline and the analytics
 * evidence is void.
 *
 * OUTPUT  (one file per frame, <out-dir>/00_000_<frame:06d>.txt)
 *
 *   frame <n> <label> <count>            per-ROI occupancy from NvDsAnalyticsFrameMeta
 *   obj <id> <class> <label> \
 *       <det l t r b> <trk l t r b> <rect l t r b> \
 *       <conf> <trk_conf> <roi|->        per object
 *
 *   `rect` is what nvdsanalytics actually consumed (obj_meta->rect_params);
 *   `trk` is tracker_bbox_info.org_bbox_coords, which is what deepstream-app's
 *   kitti-track dump records; `det` is detector_bbox_info.org_bbox_coords.
 *   Keeping all three is what makes the cross-check possible.
 *
 * MILESTONE 9.2 ADDITION -- TRANSITION EVENTS  (--events-output)
 * -------------------------------------------------------------
 * The per-frame output above is a STATE dump: it answers "who is in the zone on
 * frame N". A surveillance consumer wants EVENTS -- "someone entered" -- not the
 * same inside-state repeated once per frame. At 30 fps a per-frame state feed is
 * ~350 MB/day of messages that say nothing new.
 *
 * With --events-output, the probe additionally writes JSON Lines, one event per
 * line, on ROI membership TRANSITIONS only:
 *
 *   zone_enter   a (track, roi) pair that was outside is now inside
 *   zone_exit    a (track, roi) pair that was inside is now outside, OR the
 *                track disappeared while still inside (exit_reason says which)
 *
 * State is keyed by (object_id, roi_label), so several tracked people and
 * several ROIs work without anything being hard-coded.
 *
 * This is ADDITIVE. Without --events-output not one byte of existing behaviour
 * changes, which is what keeps verify_zone.sh and verify_triton.sh valid.
 *
 * See docs/milestone-09-events.md for the schema and the frame conventions.
 *
 * MILESTONE 9.3 ADDITION -- MQTT TRANSPORT  (--mqtt-host, compile-time optional)
 * -----------------------------------------------------------------------------
 * The SAME serialized JSON string that is written as a JSONL line is published
 * to an MQTT topic. One event object, serialized ONCE:
 *
 *     ROI transition -> event object -> serialize once -> +-- JSONL line
 *                                                         +-- MQTT payload
 *
 * That is the whole point. MQTT here is a TRANSPORT for an already-verified
 * event, not a second interpretation of the metadata -- so a subscriber's bytes
 * can be compared against the file's bytes and must match exactly.
 *
 * COMPILE-TIME OPTIONAL. libmosquitto's headers are present in the Milestone 7
 * container but NOT on this host, so:
 *
 *     make -C tools                 -> build/analytics_probe       no MQTT code
 *     make -C tools mqtt            -> build/analytics_probe_mqtt  MQTT enabled
 *                                      (must be built IN the container)
 *
 * Two binaries rather than one, deliberately: the Milestone 5/7/9.2 paths keep
 * using a binary that has never linked libmosquitto, so whichever build ran last
 * cannot change another milestone's result. Without -DHAVE_MOSQUITTO the MQTT
 * options are still PARSED, and rejected with a clear message, rather than
 * silently ignored.
 *
 * See docs/milestone-09-mqtt.md.
 */

#include <gst/gst.h>
#include <glib.h>

#include <cstdio>
#include <cstring>
#include <map>
#include <set>
#include <string>
#include <utility>
#include <vector>

#include "gstnvdsmeta.h"
#include "nvdsmeta.h"
#include "nvds_analytics_meta.h"

#ifdef HAVE_MOSQUITTO
#include <mosquitto.h>
#endif

namespace {

struct Options {
  gchar *video = nullptr;
  gchar *infer_config = nullptr;
  gchar *tracker_lib = nullptr;
  gchar *tracker_config = nullptr;
  gchar *analytics_config = nullptr;
  gchar *out_dir = nullptr;
  /* "nvinfer" (Milestone 5/6) or "nvinferserver" (Milestone 7, in-process
   * Triton). The SAME tool must be able to exercise either serving layer,
   * because its whole purpose is comparing them -- forking it would mean
   * comparing two different test instruments. */
  gchar *infer_element = nullptr;
  gchar *events_output = nullptr;
  gchar *mqtt_host = nullptr;
  gchar *mqtt_topic = nullptr;
  gint mqtt_port = 1883;
  gint tracker_width = 960;
  gint tracker_height = 544;
  gint mux_width = 1920;
  gint mux_height = 1080;
};

Options opts;
guint64 g_frames_seen = 0;
gboolean g_saw_error = FALSE;

/* ---------------------------------------------------------------- events --
 *
 * Everything below is inert unless --events-output was given.
 */
FILE *g_events_fp = nullptr;
guint64 g_events_written = 0;

/* One entry per (object_id, roi_label) pair that is currently INSIDE. Its
 * presence IS the "was inside" half of the transition test. */
struct ZoneState {
  gint enter_frame;
  gdouble enter_stream_s;
  gint last_inside_frame;          /* the frame the interval will be closed AT */
  gdouble last_inside_stream_s;
  std::string cls;
};
std::map<std::pair<guint64, std::string>, ZoneState> g_zone_state;

/* Frame interval in seconds, derived from the first two buffers' PTS rather
 * than hard-coded. duration_seconds follows the project's existing convention
 * (analyze_zone.py:218): frames_inside / fps, NOT the span between the first
 * and last inside frame -- those differ by one frame interval. 0 means "not yet
 * known", in which case duration_seconds is omitted rather than guessed. */
gdouble g_frame_interval_s = 0.0;
guint64 g_prev_pts = 0;
gboolean g_have_prev_pts = FALSE;

/* Minimal JSON string escaping. The labels come from our own configs, but a
 * writer that cannot escape is a writer that silently emits invalid JSON the
 * day a config changes. */
std::string
json_escape (const std::string & in)
{
  std::string out;
  for (char c : in) {
    switch (c) {
      case '"':  out += "\\\""; break;
      case '\\': out += "\\\\"; break;
      case '\n': out += "\\n";  break;
      case '\r': out += "\\r";  break;
      case '\t': out += "\\t";  break;
      default:
        if ((unsigned char) c < 0x20) {
          gchar buf[8];
          g_snprintf (buf, sizeof (buf), "\\u%04x", c);
          out += buf;
        } else {
          out += c;
        }
    }
  }
  return out;
}

/* Host wall clock, ISO 8601 UTC with milliseconds.
 *
 * WHY THE HOST CLOCK AND NOT ntp_timestamp. nvstreammux's attach-sys-ts
 * defaults to TRUE, so on a FILE source ntp_timestamp is the system time at
 * which the buffer reached the mux -- processing time, not capture time. For a
 * recorded clip replayed unpaced there is no true capture wall-clock at all.
 * Calling a processing timestamp a capture timestamp would be a lie, so this
 * field is named for what it is: when THIS SYSTEM observed the event. Position
 * within the source is reported separately as stream_time_seconds. */
std::string
iso8601_utc_now ()
{
  gint64 us = g_get_real_time ();
  GDateTime *dt = g_date_time_new_from_unix_utc (us / G_USEC_PER_SEC);
  if (!dt)
    return "";
  gchar *base = g_date_time_format (dt, "%Y-%m-%dT%H:%M:%S");
  gchar *full = g_strdup_printf ("%s.%03dZ", base,
      (gint) ((us % G_USEC_PER_SEC) / 1000));
  std::string out = full;
  g_free (full);
  g_free (base);
  g_date_time_unref (dt);
  return out;
}

/* ------------------------------------------------------------------ MQTT --
 *
 * Milestone 9.3. Inert unless --mqtt-host was given, and absent from the binary
 * entirely unless compiled with -DHAVE_MOSQUITTO.
 */
gboolean g_mqtt_enabled = FALSE;
guint64 g_mqtt_published = 0;      /* publish calls that returned MOSQ_ERR_SUCCESS */
guint64 g_mqtt_acked = 0;          /* PUBACKs the broker actually sent back */
guint64 g_mqtt_failures = 0;

#ifdef HAVE_MOSQUITTO
struct mosquitto *g_mosq = nullptr;

/* QoS 1 means the broker ACKNOWLEDGES each message with a PUBACK. Counting them
 * is what turns "we called publish" into "the broker took delivery" -- the
 * difference between hoping and knowing. */
void
on_publish (struct mosquitto *mosq, void *obj, int mid)
{
  g_mqtt_acked++;
}

void
on_log (struct mosquitto *mosq, void *obj, int level, const char *str)
{
  if (level == MOSQ_LOG_ERR || level == MOSQ_LOG_WARNING)
    g_printerr ("mqtt: %s\n", str);
}
#endif

/* Serialize the event EXACTLY ONCE.
 *
 * Both sinks receive this identical string, which is what makes the Milestone
 * 9.3 verification meaningful: a subscriber's bytes can be compared with the
 * file's bytes, and any difference is a transport fault rather than two
 * serializers disagreeing. Building the JSON twice -- once for the file and
 * once for the wire -- would quietly destroy that property.
 *
 * frame_number and stream_time_seconds describe the frame the event is
 * ATTRIBUTED to, which for zone_exit is the last frame of the completed
 * interval -- see docs/milestone-09-events.md. */
std::string
serialize_event (const gchar * event, gint frame_number, gdouble stream_s,
    const std::string & zone, guint64 track_id, const std::string & cls,
    guint occupancy, gboolean have_interval, gint frames_inside,
    const gchar * exit_reason)
{
  gchar *head = g_strdup_printf (
      "{\"event\":\"%s\",\"event_time_utc\":\"%s\",\"frame_number\":%d,"
      "\"stream_time_seconds\":%.3f,\"zone\":\"%s\",\"track_id\":%lu,"
      "\"class\":\"%s\",\"occupancy\":%u",
      event, iso8601_utc_now ().c_str (), frame_number, stream_s,
      json_escape (zone).c_str (), (gulong) track_id,
      json_escape (cls).c_str (), occupancy);
  std::string out = head;
  g_free (head);

  if (have_interval) {
    gchar *fi = g_strdup_printf (",\"frames_inside\":%d", frames_inside);
    out += fi;
    g_free (fi);
    if (g_frame_interval_s > 0.0) {
      gchar *ds = g_strdup_printf (",\"duration_seconds\":%.3f",
          frames_inside * g_frame_interval_s);
      out += ds;
      g_free (ds);
    }
  }
  if (exit_reason) {
    gchar *er = g_strdup_printf (",\"exit_reason\":\"%s\"", exit_reason);
    out += er;
    g_free (er);
  }
  out += "}";
  return out;
}

/* Fan the one serialized payload out to both sinks. */
void
emit_event (const gchar * event, gint frame_number, gdouble stream_s,
    const std::string & zone, guint64 track_id, const std::string & cls,
    guint occupancy, gboolean have_interval, gint frames_inside,
    const gchar * exit_reason)
{
  if (!g_events_fp && !g_mqtt_enabled)
    return;

  const std::string payload = serialize_event (event, frame_number, stream_s,
      zone, track_id, cls, occupancy, have_interval, frames_inside,
      exit_reason);

  if (g_events_fp) {
    fprintf (g_events_fp, "%s\n", payload.c_str ());
    /* Flushed per event: a consumer tailing the file, or a run that is killed,
     * must not lose events to a stdio buffer. The volume is transitions, not
     * frames, so this costs nothing. */
    fflush (g_events_fp);
    g_events_written++;
  }

#ifdef HAVE_MOSQUITTO
  if (g_mqtt_enabled && g_mosq) {
    /* retain=false. A retained intrusion alert would be redelivered to every
     * future subscriber as though it had just happened -- a stale "person in
     * the restricted zone" is worse than no message. */
    int rc = mosquitto_publish (g_mosq, NULL, opts.mqtt_topic,
        (int) payload.size (), payload.data (), 1 /* QoS 1 */, false);
    if (rc == MOSQ_ERR_SUCCESS) {
      g_mqtt_published++;
    } else {
      g_mqtt_failures++;
      g_printerr ("ERROR: mqtt publish failed: %s\n", mosquitto_strerror (rc));
    }
  }
#endif
}

/* Connect once, before the pipeline starts. No retry loop: a broker that is not
 * there is a fact to report, not a thing to wait for, and an unbounded retry in
 * a bounded verification run is how a test hangs.
 *
 * Returns FALSE on failure. The CALLER decides what that means -- see main().
 */
gboolean
mqtt_connect ()
{
#ifdef HAVE_MOSQUITTO
  mosquitto_lib_init ();
  g_mosq = mosquitto_new (NULL, true /* clean session */, NULL);
  if (!g_mosq) {
    g_printerr ("ERROR: mqtt: could not create a client.\n");
    return FALSE;
  }
  mosquitto_publish_callback_set (g_mosq, on_publish);
  mosquitto_log_callback_set (g_mosq, on_log);

  int rc = mosquitto_connect (g_mosq, opts.mqtt_host, opts.mqtt_port,
      30 /* keepalive seconds */);
  if (rc != MOSQ_ERR_SUCCESS) {
    g_printerr ("ERROR: mqtt: cannot connect to %s:%d -- %s\n",
        opts.mqtt_host, opts.mqtt_port, mosquitto_strerror (rc));
    mosquitto_destroy (g_mosq);
    g_mosq = NULL;
    return FALSE;
  }
  /* Threaded loop: PUBACKs arrive while the DeepStream pipeline is running,
   * without this probe having to pump the socket from a pad probe. */
  rc = mosquitto_loop_start (g_mosq);
  if (rc != MOSQ_ERR_SUCCESS) {
    g_printerr ("ERROR: mqtt: could not start the network loop -- %s\n",
        mosquitto_strerror (rc));
    mosquitto_destroy (g_mosq);
    g_mosq = NULL;
    return FALSE;
  }
  g_print ("mqtt: connected to %s:%d, topic '%s', QoS 1, retain=false\n",
      opts.mqtt_host, opts.mqtt_port, opts.mqtt_topic);
  return TRUE;
#else
  g_printerr ("ERROR: this binary was built without MQTT support.\n"
      "       Rebuild with: make -C tools mqtt   (needs libmosquitto headers,\n"
      "       which are present in the Milestone 7 container, not on the host)\n");
  return FALSE;
#endif
}

/* Bounded drain, then a clean disconnect. Waits only for PUBACKs that are
 * already outstanding; it does not wait on an idle broker forever. */
void
mqtt_shutdown ()
{
#ifdef HAVE_MOSQUITTO
  if (!g_mosq)
    return;
  for (int i = 0; i < 50 && g_mqtt_acked < g_mqtt_published; i++)
    g_usleep (100 * 1000);          /* up to 5 s total */
  mosquitto_disconnect (g_mosq);
  mosquitto_loop_stop (g_mosq, false);
  mosquitto_destroy (g_mosq);
  g_mosq = NULL;
  mosquitto_lib_cleanup ();
#endif
}

/* Close an open interval. Used by both the ordinary "left the ROI" path and the
 * track-termination path; the only difference is exit_reason and which frame
 * the event is attributed to. */
void
close_interval (const std::pair<guint64, std::string> &key, const ZoneState &st,
    guint occupancy, const gchar * exit_reason)
{
  gint frames_inside = st.last_inside_frame - st.enter_frame + 1;
  emit_event ("zone_exit", st.last_inside_frame, st.last_inside_stream_s,
      key.second, key.first, st.cls, occupancy, TRUE, frames_inside,
      exit_reason);
}

/* Escape nothing, quote nothing: these paths come from our own scripts. But a
 * path containing a space would break gst_parse_launch, so refuse it loudly
 * rather than produce a confusing parse error. */
gboolean
path_is_safe (const gchar * path, const gchar * what)
{
  if (!path || !*path) {
    g_printerr ("ERROR: %s was not provided.\n", what);
    return FALSE;
  }
  if (strpbrk (path, " \t\"'!")) {
    g_printerr ("ERROR: %s contains a character that cannot be used in a "
        "gst_parse_launch description: '%s'\n", what, path);
    return FALSE;
  }
  if (!g_file_test (path, G_FILE_TEST_EXISTS)) {
    g_printerr ("ERROR: %s does not exist: '%s'\n", what, path);
    return FALSE;
  }
  return TRUE;
}

/* Second probe, on nvinfer's src pad -- strictly BEFORE the tracker.
 *
 * This exists because post-tracker object counts cannot be compared against
 * deepstream-app's detector dump: the tracker legitimately removes objects it
 * has not claimed (removeUntrackedObjects, nvtracker_proc.cpp:2169). Without a
 * pre-tracker record there is no way to tell a detector difference from a
 * tracker difference, and the cross-check would be measuring the wrong thing.
 *
 * Written to pgie_<...>.txt so it does not collide with the per-frame analytics
 * files, which the analysis globs as 00_000_*.txt.
 */
GstPadProbeReturn
pgie_src_probe (GstPad * pad, GstPadProbeInfo * info, gpointer user_data)
{
  GstBuffer *buf = (GstBuffer *) info->data;
  NvDsBatchMeta *batch_meta = gst_buffer_get_nvds_batch_meta (buf);
  if (!batch_meta)
    return GST_PAD_PROBE_OK;

  for (NvDsMetaList * l_frame = batch_meta->frame_meta_list; l_frame != NULL;
      l_frame = l_frame->next) {
    NvDsFrameMeta *frame_meta = (NvDsFrameMeta *) l_frame->data;

    gchar path[2048];
    g_snprintf (path, sizeof (path) - 1, "%s/pgie_%02u_%03u_%06lu.txt",
        opts.out_dir, 0, frame_meta->pad_index,
        (gulong) frame_meta->frame_num);

    FILE *fp = fopen (path, "w");
    if (!fp) {
      g_printerr ("ERROR: cannot write '%s'\n", path);
      g_saw_error = TRUE;
      continue;
    }
    for (NvDsMetaList * l_obj = frame_meta->obj_meta_list; l_obj != NULL;
        l_obj = l_obj->next) {
      NvDsObjectMeta *obj = (NvDsObjectMeta *) l_obj->data;
      const NvOSD_RectParams &r = obj->rect_params;
      fprintf (fp, "det %d %s %f %f %f %f %f\n", obj->class_id, obj->obj_label,
          r.left, r.top, r.left + r.width, r.top + r.height, obj->confidence);
    }
    fclose (fp);
  }
  return GST_PAD_PROBE_OK;
}

/* The probe. Runs on every buffer leaving nvdsanalytics. */
GstPadProbeReturn
analytics_src_probe (GstPad * pad, GstPadProbeInfo * info, gpointer user_data)
{
  GstBuffer *buf = (GstBuffer *) info->data;
  NvDsBatchMeta *batch_meta = gst_buffer_get_nvds_batch_meta (buf);

  if (!batch_meta) {
    g_printerr ("ERROR: no NvDsBatchMeta on a buffer leaving nvdsanalytics.\n");
    g_saw_error = TRUE;
    return GST_PAD_PROBE_OK;
  }

  for (NvDsMetaList * l_frame = batch_meta->frame_meta_list; l_frame != NULL;
      l_frame = l_frame->next) {
    NvDsFrameMeta *frame_meta = (NvDsFrameMeta *) l_frame->data;

    gchar path[2048];
    g_snprintf (path, sizeof (path) - 1, "%s/%02u_%03u_%06lu.txt",
        opts.out_dir, 0, frame_meta->pad_index,
        (gulong) frame_meta->frame_num);

    FILE *fp = fopen (path, "w");
    if (!fp) {
      g_printerr ("ERROR: cannot write '%s'\n", path);
      g_saw_error = TRUE;
      continue;
    }

    /* ---- frame-level: NvDsAnalyticsFrameMeta ---------------------------- */
    /* Written even when empty, so a frame with nobody in the zone is an
     * explicit "RF 0" rather than an absence that could mean anything. */
    gboolean wrote_roi_line = FALSE;
    std::map<std::string, guint> occupancy;      /* events only */
    for (NvDsMetaList * l_user = frame_meta->frame_user_meta_list;
        l_user != NULL; l_user = l_user->next) {
      NvDsUserMeta *user_meta = (NvDsUserMeta *) l_user->data;
      if (user_meta->base_meta.meta_type != NVDS_USER_FRAME_META_NVDSANALYTICS)
        continue;
      NvDsAnalyticsFrameMeta *ameta =
          (NvDsAnalyticsFrameMeta *) user_meta->user_meta_data;
      for (const auto & entry : ameta->objInROIcnt) {
        fprintf (fp, "frame %lu %s %u\n", (gulong) frame_meta->frame_num,
            entry.first.c_str (), entry.second);
        occupancy[entry.first] = entry.second;
        wrote_roi_line = TRUE;
      }
    }
    if (!wrote_roi_line) {
      /* No analytics frame meta at all -- distinct from "meta present, count 0",
       * and the verification must be able to tell those apart. */
      fprintf (fp, "frame %lu NOMETA 0\n", (gulong) frame_meta->frame_num);
    }

    /* ---- object level --------------------------------------------------- */
    /* (object_id, roi_label) pairs inside an ROI on THIS frame. Built while the
     * per-frame file is written so the two views cannot diverge -- they read
     * the same metadata in the same pass. Events only. */
    std::set<std::pair<guint64, std::string> > present;
    std::map<guint64, std::string> class_of;

    for (NvDsMetaList * l_obj = frame_meta->obj_meta_list; l_obj != NULL;
        l_obj = l_obj->next) {
      NvDsObjectMeta *obj = (NvDsObjectMeta *) l_obj->data;

      std::string roi = "-";
      for (NvDsMetaList * l_ouser = obj->obj_user_meta_list; l_ouser != NULL;
          l_ouser = l_ouser->next) {
        NvDsUserMeta *ouser = (NvDsUserMeta *) l_ouser->data;
        if (ouser->base_meta.meta_type != NVDS_USER_OBJ_META_NVDSANALYTICS)
          continue;
        NvDsAnalyticsObjInfo *oinfo =
            (NvDsAnalyticsObjInfo *) ouser->user_meta_data;
        std::string joined;
        for (const auto & label : oinfo->roiStatus) {
          if (!joined.empty ())
            joined += ",";
          joined += label;
          if (g_events_fp) {
            present.insert (std::make_pair ((guint64) obj->object_id, label));
            /* obj_label is a fixed-size array in NvDsObjectMeta, so it is
             * never NULL -- only possibly empty. */
            class_of[(guint64) obj->object_id] = obj->obj_label;
          }
        }
        if (!joined.empty ())
          roi = joined;
      }

      const NvBbox_Coords &d = obj->detector_bbox_info.org_bbox_coords;
      const NvBbox_Coords &t = obj->tracker_bbox_info.org_bbox_coords;
      const NvOSD_RectParams &r = obj->rect_params;

      fprintf (fp,
          "obj %lu %d %s %f %f %f %f %f %f %f %f %f %f %f %f %f %f %s\n",
          (gulong) obj->object_id, obj->class_id, obj->obj_label,
          d.left, d.top, d.left + d.width, d.top + d.height,
          t.left, t.top, t.left + t.width, t.top + t.height,
          r.left, r.top, r.left + r.width, r.top + r.height,
          obj->confidence, obj->tracker_confidence, roi.c_str ());
    }

    fclose (fp);
    g_frames_seen++;

    /* ---- Milestone 9.2: ROI membership TRANSITIONS ---------------------- */
    if (!g_events_fp)
      continue;

    const gint fnum = (gint) frame_meta->frame_num;
    const gdouble stream_s = (gdouble) frame_meta->buf_pts / 1e9;

    /* Frame interval from the first two buffers, so no frame rate is
     * hard-coded here or in any config this tool reads. */
    if (!g_have_prev_pts) {
      g_prev_pts = frame_meta->buf_pts;
      g_have_prev_pts = TRUE;
      /* Recorded once, as the evidence for the timestamp decision above. */
      g_printerr ("events: first frame buf_pts=%lu ns  ntp_timestamp=%lu\n",
          (gulong) frame_meta->buf_pts, (gulong) frame_meta->ntp_timestamp);
    } else if (g_frame_interval_s == 0.0 && frame_meta->buf_pts > g_prev_pts) {
      g_frame_interval_s = (gdouble) (frame_meta->buf_pts - g_prev_pts) / 1e9;
      g_printerr ("events: frame interval %.6f s (%.2f fps), derived from PTS\n",
          g_frame_interval_s, 1.0 / g_frame_interval_s);
    }

    /* ENTER: inside now, no open interval. Also refresh the close-at frame for
     * intervals that are still open, which is what lets zone_exit be
     * attributed to the LAST INSIDE frame rather than the first outside one. */
    for (const auto & key : present) {
      auto it = g_zone_state.find (key);
      if (it == g_zone_state.end ()) {
        ZoneState st;
        st.enter_frame = fnum;
        st.enter_stream_s = stream_s;
        st.last_inside_frame = fnum;
        st.last_inside_stream_s = stream_s;
        st.cls = class_of[key.first];
        g_zone_state[key] = st;
        guint occ = occupancy.count (key.second) ? occupancy[key.second] : 0;
        emit_event ("zone_enter", fnum, stream_s, key.second, key.first,
            st.cls, occ, FALSE, 0, NULL);
      } else {
        it->second.last_inside_frame = fnum;
        it->second.last_inside_stream_s = stream_s;
      }
    }

    /* EXIT: an open interval whose (track, roi) pair is not inside this frame.
     * Two distinct causes, reported distinctly:
     *   left_zone    the track is still present, just no longer in the ROI
     *   track_ended  the track is gone from obj_meta_list entirely
     * A tracker that drops a target for a single frame while it is inside the
     * ROI would therefore read as track_ended followed by a fresh zone_enter.
     * That is not observed on sample_walk.mov -- see the limitations section of
     * docs/milestone-09-events.md. */
    std::vector<std::pair<guint64, std::string> > closed;
    for (const auto & kv : g_zone_state) {
      if (present.count (kv.first))
        continue;
      gboolean track_present = (class_of.count (kv.first.first) > 0);
      if (!track_present) {
        for (NvDsMetaList * l_obj = frame_meta->obj_meta_list; l_obj != NULL;
            l_obj = l_obj->next) {
          NvDsObjectMeta *o = (NvDsObjectMeta *) l_obj->data;
          if ((guint64) o->object_id == kv.first.first) {
            track_present = TRUE;
            break;
          }
        }
      }
      guint occ = occupancy.count (kv.first.second)
          ? occupancy[kv.first.second] : 0;
      close_interval (kv.first, kv.second, occ,
          track_present ? "left_zone" : "track_ended");
      closed.push_back (kv.first);
    }
    for (const auto & key : closed)
      g_zone_state.erase (key);
  }

  return GST_PAD_PROBE_OK;
}

/* End of stream with intervals still open: the clip ended while someone was
 * inside the zone. Closing them at EOS is what stops an interval from being
 * silently dropped. NOT EXERCISED by sample_walk.mov -- the walker leaves the
 * ROI at frame 183 and the clip runs to 287. */
void
flush_open_intervals ()
{
  if (!g_events_fp)
    return;
  for (const auto & kv : g_zone_state)
    close_interval (kv.first, kv.second, 0, "stream_ended");
  g_zone_state.clear ();
}

gboolean
bus_call (GstBus * bus, GstMessage * msg, gpointer data)
{
  GMainLoop *loop = (GMainLoop *) data;
  switch (GST_MESSAGE_TYPE (msg)) {
    case GST_MESSAGE_EOS:
      g_main_loop_quit (loop);
      break;
    case GST_MESSAGE_ERROR:{
      GError *err = NULL;
      gchar *dbg = NULL;
      gst_message_parse_error (msg, &err, &dbg);
      g_printerr ("ERROR from %s: %s\n", GST_OBJECT_NAME (msg->src),
          err->message);
      if (dbg)
        g_printerr ("  debug: %s\n", dbg);
      g_clear_error (&err);
      g_free (dbg);
      g_saw_error = TRUE;
      g_main_loop_quit (loop);
      break;
    }
    case GST_MESSAGE_WARNING:{
      GError *err = NULL;
      gchar *dbg = NULL;
      gst_message_parse_warning (msg, &err, &dbg);
      g_printerr ("WARNING from %s: %s\n", GST_OBJECT_NAME (msg->src),
          err->message);
      g_clear_error (&err);
      g_free (dbg);
      break;
    }
    default:
      break;
  }
  return TRUE;
}

}  /* namespace */

int
main (int argc, char *argv[])
{
  GOptionEntry entries[] = {
    {"video", 0, 0, G_OPTION_ARG_FILENAME, &opts.video,
        "H.264-in-MOV/MP4 source file", "PATH"},
    {"infer-config", 0, 0, G_OPTION_ARG_FILENAME, &opts.infer_config,
        "nvinfer config (the same file deepstream-app uses)", "PATH"},
    {"tracker-lib", 0, 0, G_OPTION_ARG_FILENAME, &opts.tracker_lib,
        "nvtracker low-level library", "PATH"},
    {"tracker-config", 0, 0, G_OPTION_ARG_FILENAME, &opts.tracker_config,
        "nvtracker low-level config (NvSORT yml)", "PATH"},
    {"analytics-config", 0, 0, G_OPTION_ARG_FILENAME, &opts.analytics_config,
        "nvdsanalytics config", "PATH"},
    {"out-dir", 0, 0, G_OPTION_ARG_FILENAME, &opts.out_dir,
        "directory for per-frame output (must exist)", "DIR"},
    {"inference-element", 0, 0, G_OPTION_ARG_STRING, &opts.infer_element,
        "nvinfer (default) or nvinferserver", "NAME"},
    {"events-output", 0, 0, G_OPTION_ARG_FILENAME, &opts.events_output,
        "write JSON Lines zone-transition events here (optional; omitting it "
        "leaves behaviour exactly as it was before Milestone 9.2)", "PATH"},
    {"mqtt-host", 0, 0, G_OPTION_ARG_STRING, &opts.mqtt_host,
        "publish each event to this MQTT broker (optional; enables MQTT)", "HOST"},
    {"mqtt-port", 0, 0, G_OPTION_ARG_INT, &opts.mqtt_port,
        "MQTT broker port (default 1883)", "N"},
    {"mqtt-topic", 0, 0, G_OPTION_ARG_STRING, &opts.mqtt_topic,
        "MQTT topic to publish on (required with --mqtt-host)", "TOPIC"},
    {"tracker-width", 0, 0, G_OPTION_ARG_INT, &opts.tracker_width,
        "tracker working width (default 960)", "N"},
    {"tracker-height", 0, 0, G_OPTION_ARG_INT, &opts.tracker_height,
        "tracker working height (default 544)", "N"},
    {NULL, 0, 0, G_OPTION_ARG_NONE, NULL, NULL, NULL}
  };

  GError *err = NULL;
  GOptionContext *ctx =
      g_option_context_new ("- dump nvdsanalytics metadata per frame");
  g_option_context_add_main_entries (ctx, entries, NULL);
  g_option_context_add_group (ctx, gst_init_get_option_group ());
  if (!g_option_context_parse (ctx, &argc, &argv, &err)) {
    g_printerr ("ERROR: %s\n", err->message);
    g_clear_error (&err);
    g_option_context_free (ctx);
    return 1;
  }
  g_option_context_free (ctx);

  if (!path_is_safe (opts.video, "--video")
      || !path_is_safe (opts.infer_config, "--infer-config")
      || !path_is_safe (opts.tracker_lib, "--tracker-lib")
      || !path_is_safe (opts.tracker_config, "--tracker-config")
      || !path_is_safe (opts.analytics_config, "--analytics-config"))
    return 1;

  if (!opts.out_dir || !g_file_test (opts.out_dir, G_FILE_TEST_IS_DIR)) {
    g_printerr ("ERROR: --out-dir must name an existing directory (got '%s').\n",
        opts.out_dir ? opts.out_dir : "");
    return 1;
  }

  if (!opts.infer_element)
    opts.infer_element = g_strdup ("nvinfer");
  /* BOTH elements take config-file-path. gst-inspect-1.0, in the Milestone 7
   * image:
   *     nvinfer:        config-file-path : Path to the configuration file ...
   *     nvinferserver:  config-file-path : Path to the configuration file ...
   *
   * An earlier version of this file used "config-file" for nvinferserver and
   * failed at pipeline construction with
   *     no property "config-file" in element "nvinferserver"
   * That name is real, but it belongs to a DIFFERENT namespace: `config-file=`
   * is the deepstream-app *config key* under [primary-gie] (which is what
   * configs/deepstream_app_walk_triton.txt correctly uses). The GStreamer
   * element *property* is config-file-path for both. The two namespaces are
   * easy to conflate and the element only tells you at run time.
   *
   * So the element name is the only thing that varies, which is precisely the
   * property this milestone is testing. */
  if (g_strcmp0 (opts.infer_element, "nvinfer")
      && g_strcmp0 (opts.infer_element, "nvinferserver")) {
    g_printerr ("ERROR: --inference-element must be 'nvinfer' or "
        "'nvinferserver' (got '%s').\n", opts.infer_element);
    return 1;
  }

  /* TRUNCATE, not append. Each invocation produces the events of THAT run and
   * nothing else: appending would blend runs into one file whose contents
   * depend on how many times it had been run before, which is both unverifiable
   * and unbounded. Bounding by design beats a rotation subsystem nobody asked
   * for. Opened BEFORE gst_init so a bad path fails before a pipeline exists. */
  if (opts.events_output) {
    g_events_fp = fopen (opts.events_output, "w");
    if (!g_events_fp) {
      g_printerr ("ERROR: cannot open --events-output '%s' for writing.\n",
          opts.events_output);
      return 1;
    }
  }

  /* MQTT is opt-in and must be configured explicitly: no broker address and no
   * topic are compiled in, so a misconfigured run cannot quietly publish
   * surveillance events somewhere nobody intended. */
  gboolean mqtt_requested = (opts.mqtt_host != NULL);
  if (mqtt_requested) {
    if (!opts.mqtt_topic || !*opts.mqtt_topic) {
      g_printerr ("ERROR: --mqtt-host requires --mqtt-topic.\n");
      if (g_events_fp)
        fclose (g_events_fp);
      return 1;
    }
    if (opts.mqtt_port <= 0 || opts.mqtt_port > 65535) {
      g_printerr ("ERROR: --mqtt-port must be 1..65535 (got %d).\n",
          opts.mqtt_port);
      if (g_events_fp)
        fclose (g_events_fp);
      return 1;
    }
    g_mqtt_enabled = mqtt_connect ();
    /* DELIVERY FAILURE POLICY. The reliability hierarchy is analytics -> JSONL
     * (primary local record) -> MQTT (transport). A broker outage is a
     * TRANSPORT failure and must not stop the surveillance system recording
     * locally, so the pipeline still runs and still writes JSONL. The run then
     * exits non-zero at the end, so the transport failure is impossible to
     * mistake for success. */
    if (!g_mqtt_enabled)
      g_printerr ("WARNING: MQTT was requested but is unavailable. The run will "
          "continue and still write local JSONL evidence, then exit non-zero.\n");
  }

  gst_init (NULL, NULL);

  /* The same element chain deepstream-app builds, minus the OSD and the real
   * sink -- both of which sit DOWNSTREAM of the probe point and so cannot
   * influence what is measured. The tiler is kept anyway, to stay as close to
   * the application pipeline as possible. Every configuration file is the one
   * the application uses; none is duplicated here. */
  gchar *desc = g_strdup_printf (
      "filesrc location=%s ! qtdemux name=dmx "
      "dmx.video_0 ! queue ! h264parse ! nvv4l2decoder ! mux.sink_0 "
      "nvstreammux name=mux batch-size=1 width=%d height=%d "
      "live-source=0 batched-push-timeout=40000 ! "
      "%s name=pgie config-file-path=%s ! "
      /* Every property create_tracking_bin() sets, with the same values --
       * including the ones whose ELEMENT default differs from what
       * deepstream-app applies (notably tracking-id-reset-mode, which defaults
       * to 1 on the element but is forced to 0 by the application).
       *
       * A KNOWN, BOUNDED DIVERGENCE remains and is deliberately NOT papered
       * over: on frames 44-48 and 50-54 -- exactly the 5-frame probation window
       * of each of the two tracks -- deepstream-app's low-level tracker claims
       * the target immediately while this pipeline's does not, so the object is
       * still UNTRACKED here and gets dropped by removeUntrackedObjects()
       * (nvtracker_proc.cpp:2169-2192). The detector output is bit-identical on
       * all 288 frames, so the divergence is entirely in low-level tracker
       * state, and every other frame matches exactly.
       *
       * Setting operate-on-class-ids=2 makes the object COUNTS agree, because
       * that gate also disables the removal -- but the retained objects still
       * carry UNTRACKED_OBJECT_ID and an empty tracker bbox, so it hides the
       * difference instead of resolving it. It is deliberately NOT set.
       * verify_zone.sh bounds the divergence instead, and requires it to lie
       * far outside the ROI interval. See docs/milestone-05-restricted-zone.md */
      "nvtracker name=trk tracker-width=%d tracker-height=%d "
      "ll-lib-file=%s ll-config-file=%s display-tracking-id=1 "
      "tracking-id-reset-mode=0 tracking-surface-type=0 input-tensor-meta=false "
      "tensor-meta-gie-id=0 compute-hw=0 user-meta-pool-size=32 ! "
      "nvdsanalytics name=analytics config-file=%s ! "
      "nvmultistreamtiler rows=1 columns=1 width=%d height=%d ! "
      "fakesink name=sink sync=0",
      opts.video, opts.mux_width, opts.mux_height,
      opts.infer_element, opts.infer_config,
      opts.tracker_width, opts.tracker_height,
      opts.tracker_lib, opts.tracker_config,
      opts.analytics_config,
      opts.mux_width, opts.mux_height);

  g_print ("pipeline: %s\n", desc);

  GstElement *pipeline = gst_parse_launch (desc, &err);
  g_free (desc);
  if (!pipeline || err) {
    g_printerr ("ERROR: could not build the pipeline: %s\n",
        err ? err->message : "unknown");
    g_clear_error (&err);
    return 1;
  }

  GstElement *analytics = gst_bin_get_by_name (GST_BIN (pipeline), "analytics");
  if (!analytics) {
    g_printerr ("ERROR: nvdsanalytics was not instantiated.\n");
    gst_object_unref (pipeline);
    return 1;
  }
  GstPad *src_pad = gst_element_get_static_pad (analytics, "src");
  if (!src_pad) {
    g_printerr ("ERROR: nvdsanalytics has no src pad.\n");
    gst_object_unref (analytics);
    gst_object_unref (pipeline);
    return 1;
  }
  gst_pad_add_probe (src_pad, GST_PAD_PROBE_TYPE_BUFFER,
      analytics_src_probe, NULL, NULL);
  gst_object_unref (src_pad);
  gst_object_unref (analytics);

  GstElement *pgie = gst_bin_get_by_name (GST_BIN (pipeline), "pgie");
  if (!pgie) {
    g_printerr ("ERROR: nvinfer was not instantiated.\n");
    gst_object_unref (pipeline);
    return 1;
  }
  GstPad *pgie_pad = gst_element_get_static_pad (pgie, "src");
  gst_pad_add_probe (pgie_pad, GST_PAD_PROBE_TYPE_BUFFER,
      pgie_src_probe, NULL, NULL);
  gst_object_unref (pgie_pad);
  gst_object_unref (pgie);

  GMainLoop *loop = g_main_loop_new (NULL, FALSE);
  GstBus *bus = gst_pipeline_get_bus (GST_PIPELINE (pipeline));
  guint watch_id = gst_bus_add_watch (bus, bus_call, loop);
  gst_object_unref (bus);

  if (gst_element_set_state (pipeline,
          GST_STATE_PLAYING) == GST_STATE_CHANGE_FAILURE) {
    g_printerr ("ERROR: could not set the pipeline to PLAYING.\n");
    g_source_remove (watch_id);
    g_main_loop_unref (loop);
    gst_object_unref (pipeline);
    return 1;
  }

  g_main_loop_run (loop);

  gst_element_set_state (pipeline, GST_STATE_NULL);
  g_source_remove (watch_id);
  g_main_loop_unref (loop);
  gst_object_unref (pipeline);

  flush_open_intervals ();
  mqtt_shutdown ();

  g_print ("frames written: %lu\n", (gulong) g_frames_seen);
  if (g_events_fp) {
    g_print ("events written: %lu\n", (gulong) g_events_written);
    if (fclose (g_events_fp) != 0) {
      g_printerr ("ERROR: failed to close the event file cleanly.\n");
      g_events_fp = NULL;
      return 1;
    }
    g_events_fp = NULL;
  }
  if (mqtt_requested) {
    /* Reported as three separate numbers on purpose. published is what this
     * process handed to the client library; acked is what the broker confirmed
     * with a PUBACK. QoS 1 is AT LEAST ONCE, so acked == published means every
     * message was taken by the broker -- it is not a claim of exactly-once. */
    g_print ("mqtt published: %lu\n", (gulong) g_mqtt_published);
    g_print ("mqtt acked: %lu\n", (gulong) g_mqtt_acked);
    g_print ("mqtt failures: %lu\n", (gulong) g_mqtt_failures);
  }

  if (g_saw_error)
    return 1;
  /* MQTT was asked for and did not fully work. The surveillance result above is
   * still valid and the JSONL is still on disk; what failed is delivery, and
   * that must be visible in the exit status rather than buried in the log. */
  if (mqtt_requested) {
    if (!g_mqtt_enabled) {
      g_printerr ("ERROR: MQTT was requested but no connection was established. "
          "Local JSONL evidence was still written.\n");
      return 1;
    }
    if (g_mqtt_failures > 0 || g_mqtt_acked < g_mqtt_published) {
      g_printerr ("ERROR: MQTT delivery incomplete: %lu published, %lu acked, "
          "%lu failed.\n", (gulong) g_mqtt_published, (gulong) g_mqtt_acked,
          (gulong) g_mqtt_failures);
      return 1;
    }
  }
  if (g_frames_seen == 0) {
    g_printerr ("ERROR: the pipeline ran but no frame reached nvdsanalytics.\n");
    return 1;
  }
  return 0;
}
