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
 */

#include <gst/gst.h>
#include <glib.h>

#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "gstnvdsmeta.h"
#include "nvdsmeta.h"
#include "nvds_analytics_meta.h"

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
  gint tracker_width = 960;
  gint tracker_height = 544;
  gint mux_width = 1920;
  gint mux_height = 1080;
};

Options opts;
guint64 g_frames_seen = 0;
gboolean g_saw_error = FALSE;

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
        wrote_roi_line = TRUE;
      }
    }
    if (!wrote_roi_line) {
      /* No analytics frame meta at all -- distinct from "meta present, count 0",
       * and the verification must be able to tell those apart. */
      fprintf (fp, "frame %lu NOMETA 0\n", (gulong) frame_meta->frame_num);
    }

    /* ---- object level --------------------------------------------------- */
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
  }

  return GST_PAD_PROBE_OK;
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

  g_print ("frames written: %lu\n", (gulong) g_frames_seen);

  if (g_saw_error)
    return 1;
  if (g_frames_seen == 0) {
    g_printerr ("ERROR: the pipeline ran but no frame reached nvdsanalytics.\n");
    return 1;
  }
  return 0;
}
