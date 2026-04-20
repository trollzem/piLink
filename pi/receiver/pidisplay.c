/*
 * pidisplay: zero-overhead H.264/RTP receiver for Raspberry Pi Zero 2 W.
 *
 * Pipeline, all kernel-space after the UDP recv:
 *   UDP socket -> RTP/H.264 reassembly (RFC 6184)
 *             -> V4L2 M2M H.264 decoder (/dev/video10, bcm2835-codec)
 *             -> DMA-BUF export of decoded frame
 *             -> DRM atomic page-flip on an overlay plane (/dev/dri/card0)
 *
 * No GStreamer, no ffmpeg, no userspace color conversion, no userspace copy of
 * pixel data. The capture buffer the decoder wrote is the exact memory the
 * display scans out. Buffer pool is the V4L2 minimum (no "N extra" padding
 * that frameworks typically add), which removes one-frame-worth of pipeline
 * latency vs. gstreamer.
 *
 * Build:
 *   gcc -O2 -Wall -Wextra pidisplay.c -o pidisplay -ldrm
 */

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <time.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <linux/videodev2.h>
#include <unistd.h>
#include <xf86drm.h>
#include <xf86drmMode.h>
#include <drm_fourcc.h>

#define UDP_PORT         5001
#define MAX_UDP_PKT      1600
#define MAX_NAL_SIZE     (1024 * 1024)   /* 1 MiB per NAL — plenty for 1080p H.264 */
#define NUM_OUTPUT_BUF   4
#define NUM_CAPTURE_MIN  4               /* bcm2835-codec reports ~4; we may bump on query */

/* V4L2 device for bcm2835-codec decode instance */
#define V4L2_DEV "/dev/video10"
#define DRM_DEV  "/dev/dri/card0"

static volatile sig_atomic_t g_stop = 0;
static void on_signal(int s) { (void)s; g_stop = 1; }

static void die(const char *fmt, ...) __attribute__((noreturn, format(printf, 1, 2)));
static void die(const char *fmt, ...) {
    va_list ap; va_start(ap, fmt); vfprintf(stderr, fmt, ap); va_end(ap);
    fputc('\n', stderr);
    exit(1);
}
static void info(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void info(const char *fmt, ...) {
    va_list ap; va_start(ap, fmt); vfprintf(stderr, fmt, ap); va_end(ap);
    fputc('\n', stderr);
}

/* Wrap ioctl to retry on EINTR, common in V4L2 code */
static int xioctl(int fd, unsigned long req, void *arg) {
    int r;
    do { r = ioctl(fd, req, arg); } while (r == -1 && errno == EINTR);
    return r;
}

/* -------------------- RTP/H.264 depacketizer (RFC 6184) -------------------- */

struct depay {
    uint8_t *nal;          /* reassembly buffer for the in-progress NAL */
    size_t   nal_len;
    size_t   nal_cap;
    uint16_t last_seq;     /* last RTP sequence number seen */
    bool     have_seq;
    uint32_t last_ts;
    bool     have_ts;
    bool     in_fua;       /* currently accumulating FU-A fragments */
};

static void depay_reset(struct depay *d) {
    d->nal_len = 0;
    d->in_fua = false;
}

static void depay_append_startcode(struct depay *d) {
    static const uint8_t sc[4] = {0, 0, 0, 1};
    if (d->nal_len + 4 > d->nal_cap) return;
    memcpy(d->nal + d->nal_len, sc, 4);
    d->nal_len += 4;
}

static void depay_append(struct depay *d, const uint8_t *p, size_t n) {
    if (d->nal_len + n > d->nal_cap) {
        /* Would overflow; drop this NAL. */
        d->nal_len = d->nal_cap + 1;  /* poison */
        return;
    }
    memcpy(d->nal + d->nal_len, p, n);
    d->nal_len += n;
}

/*
 * Feed a UDP packet to the depacketizer. Whenever a complete access unit is
 * ready (marker bit set), calls on_au(nal_data, nal_len, user) and resets.
 * NAL data is emitted as Annex-B (start-code prefixed) which V4L2 accepts
 * when the buffer contains one or more NALs.
 */
static void depay_feed(struct depay *d, const uint8_t *pkt, size_t len,
                       void (*on_au)(const uint8_t *, size_t, void *),
                       void *user) {
    if (len < 12) return;

    uint8_t b0 = pkt[0];
    uint8_t b1 = pkt[1];
    if ((b0 >> 6) != 2) return;                /* version must be 2 */
    bool marker = (b1 & 0x80) != 0;
    uint16_t seq = ((uint16_t)pkt[2] << 8) | pkt[3];
    uint32_t ts = ((uint32_t)pkt[4] << 24) | ((uint32_t)pkt[5] << 16) |
                  ((uint32_t)pkt[6] << 8)  | (uint32_t)pkt[7];
    (void)ts;
    size_t hdr = 12 + 4 * (b0 & 0x0F);          /* V=2,P,X,CC bits */
    bool has_ext = (b0 & 0x10) != 0;
    if (has_ext) {
        if (hdr + 4 > len) return;
        uint16_t ext_len = ((uint16_t)pkt[hdr + 2] << 8) | pkt[hdr + 3];
        hdr += 4 + 4 * ext_len;
    }
    if (hdr >= len) return;
    const uint8_t *pl = pkt + hdr;
    size_t pl_len = len - hdr;

    /* Drop non-contiguous sequence if in middle of FU-A reassembly. */
    if (d->have_seq && (uint16_t)(seq - d->last_seq) != 1 && d->in_fua) {
        depay_reset(d);
    }
    d->last_seq = seq;
    d->have_seq = true;

    uint8_t nal_hdr = pl[0];
    uint8_t type = nal_hdr & 0x1F;

    if (type >= 1 && type <= 23) {
        /* Single NAL unit. */
        depay_append_startcode(d);
        depay_append(d, pl, pl_len);
    } else if (type == 24) {
        /* STAP-A: aggregation of multiple NALs. Not emitted by our sender,
         * but handle it anyway for robustness. */
        size_t off = 1;
        while (off + 2 <= pl_len) {
            uint16_t nlen = ((uint16_t)pl[off] << 8) | pl[off + 1];
            off += 2;
            if (off + nlen > pl_len) break;
            depay_append_startcode(d);
            depay_append(d, pl + off, nlen);
            off += nlen;
        }
    } else if (type == 28) {
        /* FU-A fragmentation. */
        if (pl_len < 2) return;
        uint8_t fu_hdr = pl[1];
        bool s = (fu_hdr & 0x80) != 0;
        bool e = (fu_hdr & 0x40) != 0;
        uint8_t orig_type = fu_hdr & 0x1F;
        if (s) {
            depay_append_startcode(d);
            uint8_t synth = (nal_hdr & 0xE0) | orig_type;
            depay_append(d, &synth, 1);
            d->in_fua = true;
        }
        if (!d->in_fua) return;
        depay_append(d, pl + 2, pl_len - 2);
        if (e) d->in_fua = false;
    } else {
        /* Unknown type — ignore. */
        return;
    }

    if (marker) {
        if (d->nal_len > 0 && d->nal_len <= d->nal_cap) {
            on_au(d->nal, d->nal_len, user);
        }
        depay_reset(d);
    }
}

/* -------------------- V4L2 M2M decoder -------------------- */

struct v4l2_buf {
    int      index;
    int      dmabuf_fd;       /* capture-side only, from VIDIOC_EXPBUF */
    void    *mmap_addr;       /* output-side only, bitstream buffer */
    size_t   mmap_size;
    uint32_t drm_fb_id;       /* capture-side only, from drmModeAddFB2 */
};

struct decoder {
    int fd;
    int n_out;
    int n_cap;
    struct v4l2_buf out[NUM_OUTPUT_BUF];
    struct v4l2_buf *cap;
    int cap_width;           /* padded buffer width (16-pixel aligned) */
    int cap_height;          /* padded buffer height (16-pixel aligned) */
    int visible_width;       /* actual image width */
    int visible_height;      /* actual image height */
    uint32_t cap_fourcc;     /* V4L2 fourcc, e.g. NV12 */
    bool capture_streaming;
};

static int dec_open(struct decoder *d) {
    d->fd = open(V4L2_DEV, O_RDWR | O_NONBLOCK | O_CLOEXEC);
    if (d->fd < 0) die("open %s: %s", V4L2_DEV, strerror(errno));

    struct v4l2_capability cap = {0};
    if (xioctl(d->fd, VIDIOC_QUERYCAP, &cap) < 0) die("QUERYCAP");
    if (!(cap.capabilities & V4L2_CAP_VIDEO_M2M_MPLANE)) die("device not M2M mplane");
    info("v4l2: driver=%s card=%s", cap.driver, cap.card);

    /* Subscribe to SOURCE_CHANGE so we know when to configure the capture queue. */
    struct v4l2_event_subscription sub = {0};
    sub.type = V4L2_EVENT_SOURCE_CHANGE;
    if (xioctl(d->fd, VIDIOC_SUBSCRIBE_EVENT, &sub) < 0)
        info("warn: subscribe SOURCE_CHANGE failed: %s", strerror(errno));

    /* Set H.264 on the OUTPUT queue. Use generous max so the decoder can handle
     * any resolution up to 1080p without us having to know it in advance. */
    struct v4l2_format fmt = {0};
    fmt.type = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
    fmt.fmt.pix_mp.pixelformat = V4L2_PIX_FMT_H264;
    fmt.fmt.pix_mp.width  = 1920;
    fmt.fmt.pix_mp.height = 1088;
    fmt.fmt.pix_mp.num_planes = 1;
    fmt.fmt.pix_mp.plane_fmt[0].sizeimage = 1024 * 1024;
    if (xioctl(d->fd, VIDIOC_S_FMT, &fmt) < 0) die("S_FMT OUTPUT");

    /* Allocate bitstream input buffers (MMAP). */
    struct v4l2_requestbuffers req = {0};
    req.count = NUM_OUTPUT_BUF;
    req.type = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
    req.memory = V4L2_MEMORY_MMAP;
    if (xioctl(d->fd, VIDIOC_REQBUFS, &req) < 0) die("REQBUFS OUTPUT");
    d->n_out = req.count;

    for (int i = 0; i < d->n_out; i++) {
        struct v4l2_buffer b = {0};
        struct v4l2_plane planes[1] = {0};
        b.type = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
        b.memory = V4L2_MEMORY_MMAP;
        b.index = i;
        b.length = 1;
        b.m.planes = planes;
        if (xioctl(d->fd, VIDIOC_QUERYBUF, &b) < 0) die("QUERYBUF OUTPUT %d", i);

        d->out[i].index = i;
        d->out[i].mmap_size = planes[0].length;
        d->out[i].mmap_addr = mmap(NULL, planes[0].length, PROT_READ | PROT_WRITE,
                                   MAP_SHARED, d->fd, planes[0].m.mem_offset);
        if (d->out[i].mmap_addr == MAP_FAILED) die("mmap OUTPUT %d", i);
    }

    int type = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
    if (xioctl(d->fd, VIDIOC_STREAMON, &type) < 0) die("STREAMON OUTPUT");

    return 0;
}

/* Call when v4l2 reports SOURCE_CHANGE or on first frame: query CAPTURE format,
 * allocate DMA-BUF-exportable buffers, and stream-on. */
static int dec_setup_capture(struct decoder *d) {
    struct v4l2_format fmt = {0};
    fmt.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
    if (xioctl(d->fd, VIDIOC_G_FMT, &fmt) < 0) {
        info("G_FMT CAPTURE: %s", strerror(errno));
        return -1;
    }
    /* Prefer NV12: VC4 DRM plane supports 2-plane semi-planar directly; 3-plane
     * YU12 often fails atomic commit with ENOSPC. S_FMT to request NV12 — the
     * bcm2835-codec driver will honor it if supported. */
    fmt.fmt.pix_mp.pixelformat = V4L2_PIX_FMT_NV12;
    if (xioctl(d->fd, VIDIOC_S_FMT, &fmt) < 0)
        info("S_FMT CAPTURE NV12 failed: %s (falling back)", strerror(errno));
    /* Re-query what the driver actually accepted. */
    if (xioctl(d->fd, VIDIOC_G_FMT, &fmt) < 0) die("G_FMT CAPTURE after S_FMT");
    d->cap_width  = fmt.fmt.pix_mp.width;
    d->cap_height = fmt.fmt.pix_mp.height;
    d->cap_fourcc = fmt.fmt.pix_mp.pixelformat;

    /* Query the visible image rectangle — bcm2835-codec pads buffer dims to 16.
     * If we don't crop to the visible area the junk rows show as a green bar. */
    struct v4l2_selection sel = {0};
    sel.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
    sel.target = V4L2_SEL_TGT_COMPOSE;
    if (xioctl(d->fd, VIDIOC_G_SELECTION, &sel) == 0) {
        d->visible_width  = sel.r.width;
        d->visible_height = sel.r.height;
    } else {
        d->visible_width  = d->cap_width;
        d->visible_height = d->cap_height;
    }
    info("capture: buf %dx%d, visible %dx%d, fourcc=%.4s",
         d->cap_width, d->cap_height, d->visible_width, d->visible_height,
         (char *)&d->cap_fourcc);

    /* We want the minimum number of capture buffers the decoder will accept. */
    struct v4l2_control ctrl = { .id = V4L2_CID_MIN_BUFFERS_FOR_CAPTURE };
    int min_bufs = NUM_CAPTURE_MIN;
    if (xioctl(d->fd, VIDIOC_G_CTRL, &ctrl) == 0) min_bufs = ctrl.value;
    /* One extra for us to "hold" the currently-displayed buffer. */
    int n_cap = min_bufs + 1;
    info("capture buffers: %d (min %d + 1 displayed)", n_cap, min_bufs);

    struct v4l2_requestbuffers req = {0};
    req.count  = n_cap;
    req.type   = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
    req.memory = V4L2_MEMORY_MMAP;
    if (xioctl(d->fd, VIDIOC_REQBUFS, &req) < 0) die("REQBUFS CAPTURE");
    n_cap = req.count;
    d->n_cap = n_cap;
    d->cap = calloc(n_cap, sizeof(struct v4l2_buf));

    for (int i = 0; i < n_cap; i++) {
        struct v4l2_exportbuffer eb = {0};
        eb.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
        eb.index = i;
        eb.plane = 0;
        eb.flags = O_RDONLY | O_CLOEXEC;
        if (xioctl(d->fd, VIDIOC_EXPBUF, &eb) < 0) die("EXPBUF CAPTURE %d", i);
        d->cap[i].index = i;
        d->cap[i].dmabuf_fd = eb.fd;

        /* Queue it. */
        struct v4l2_buffer qb = {0};
        struct v4l2_plane planes[1] = {0};
        qb.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
        qb.memory = V4L2_MEMORY_MMAP;
        qb.index = i;
        qb.length = 1;
        qb.m.planes = planes;
        if (xioctl(d->fd, VIDIOC_QBUF, &qb) < 0) die("QBUF CAPTURE %d", i);
    }

    int type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
    if (xioctl(d->fd, VIDIOC_STREAMON, &type) < 0) die("STREAMON CAPTURE");
    d->capture_streaming = true;
    return 0;
}

static int dec_queue_bitstream(struct decoder *d, const uint8_t *data, size_t len) {
    /* Dequeue any done OUTPUT buffer to reuse, else find a free one on first call. */
    struct v4l2_buffer b = {0};
    struct v4l2_plane planes[1] = {0};
    b.type = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
    b.memory = V4L2_MEMORY_MMAP;
    b.length = 1;
    b.m.planes = planes;

    int idx = -1;
    if (xioctl(d->fd, VIDIOC_DQBUF, &b) == 0) {
        idx = b.index;
    } else {
        /* First N calls before any dequeue returns: cycle through. */
        static int next_idx = 0;
        idx = next_idx;
        next_idx = (next_idx + 1) % NUM_OUTPUT_BUF;
    }

    if (len > d->out[idx].mmap_size) {
        info("NAL too large (%zu > %zu), dropping", len, d->out[idx].mmap_size);
        return -1;
    }
    memcpy(d->out[idx].mmap_addr, data, len);

    struct v4l2_buffer q = {0};
    struct v4l2_plane qplanes[1] = {0};
    q.type = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
    q.memory = V4L2_MEMORY_MMAP;
    q.index = idx;
    q.length = 1;
    q.m.planes = qplanes;
    qplanes[0].bytesused = len;
    if (xioctl(d->fd, VIDIOC_QBUF, &q) < 0) {
        info("QBUF OUTPUT %d: %s", idx, strerror(errno));
        return -1;
    }
    return 0;
}

static int dec_dequeue_capture(struct decoder *d) {
    if (!d->capture_streaming) return -1;
    struct v4l2_buffer b = {0};
    struct v4l2_plane planes[1] = {0};
    b.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
    b.memory = V4L2_MEMORY_MMAP;
    b.length = 1;
    b.m.planes = planes;
    if (xioctl(d->fd, VIDIOC_DQBUF, &b) < 0) {
        if (errno != EAGAIN) info("DQBUF CAPTURE: %s", strerror(errno));
        return -1;
    }
    return b.index;
}

static int dec_requeue_capture(struct decoder *d, int idx) {
    struct v4l2_buffer b = {0};
    struct v4l2_plane planes[1] = {0};
    b.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
    b.memory = V4L2_MEMORY_MMAP;
    b.index = idx;
    b.length = 1;
    b.m.planes = planes;
    if (xioctl(d->fd, VIDIOC_QBUF, &b) < 0) {
        info("QBUF CAPTURE %d: %s", idx, strerror(errno));
        return -1;
    }
    return 0;
}

/* -------------------- DRM output -------------------- */

struct display {
    int fd;
    uint32_t connector_id;
    uint32_t crtc_id;
    uint32_t plane_id;
    drmModeModeInfo mode;
    int screen_w;
    int screen_h;
    /* Cached property IDs on the plane for atomic commits. */
    int _fb_prop;
    int _crtc_prop;
    int _src_x, _src_y, _src_w, _src_h;
    int _crtc_x, _crtc_y, _crtc_w, _crtc_h;
    /* Connector DPMS — used to put the HDMI output into standby when the
     * stream goes idle, and bring it back when frames resume. */
    uint32_t _dpms_prop;
    bool     dpms_on;
};

static uint32_t v4l2_to_drm_fourcc(uint32_t v) {
    if (v == V4L2_PIX_FMT_NV12)   return DRM_FORMAT_NV12;
    if (v == V4L2_PIX_FMT_YUV420) return DRM_FORMAT_YUV420;
    return 0;
}

static int disp_open(struct display *d) {
    d->fd = open(DRM_DEV, O_RDWR | O_CLOEXEC);
    if (d->fd < 0) die("open %s: %s", DRM_DEV, strerror(errno));

    if (drmSetClientCap(d->fd, DRM_CLIENT_CAP_UNIVERSAL_PLANES, 1) < 0) die("UNIVERSAL_PLANES");
    if (drmSetClientCap(d->fd, DRM_CLIENT_CAP_ATOMIC, 1) < 0) die("ATOMIC");

    drmModeRes *res = drmModeGetResources(d->fd);
    if (!res) die("getResources");
    drmModeConnector *conn = NULL;
    for (int i = 0; i < res->count_connectors; i++) {
        drmModeConnector *c = drmModeGetConnector(d->fd, res->connectors[i]);
        if (c && c->connection == DRM_MODE_CONNECTED && c->count_modes > 0) {
            conn = c; break;
        }
        if (c) drmModeFreeConnector(c);
    }
    if (!conn) die("no connected connector");
    d->connector_id = conn->connector_id;
    d->mode = conn->modes[0];  /* first is preferred */
    d->screen_w = d->mode.hdisplay;
    d->screen_h = d->mode.vdisplay;
    info("drm: connector %u mode %dx%d@%uHz", d->connector_id,
         d->screen_w, d->screen_h, d->mode.vrefresh);

    /* Find a CRTC capable of driving this connector. */
    drmModeEncoder *enc = drmModeGetEncoder(d->fd, conn->encoder_id);
    if (enc) {
        d->crtc_id = enc->crtc_id;
        drmModeFreeEncoder(enc);
    }
    if (!d->crtc_id) {
        for (int i = 0; i < conn->count_encoders; i++) {
            drmModeEncoder *e = drmModeGetEncoder(d->fd, conn->encoders[i]);
            if (!e) continue;
            for (int j = 0; j < res->count_crtcs; j++) {
                if (e->possible_crtcs & (1 << j)) {
                    d->crtc_id = res->crtcs[j];
                    break;
                }
            }
            drmModeFreeEncoder(e);
            if (d->crtc_id) break;
        }
    }
    if (!d->crtc_id) die("no CRTC");
    info("drm: crtc %u", d->crtc_id);
    drmModeFreeConnector(conn);

    /* Find the CRTC's index to match plane possible_crtcs bitmask. */
    int crtc_idx = -1;
    for (int i = 0; i < res->count_crtcs; i++) {
        if (res->crtcs[i] == d->crtc_id) { crtc_idx = i; break; }
    }
    drmModePlaneRes *pres = drmModeGetPlaneResources(d->fd);
    if (!pres) die("planes");
    /* Prefer an overlay plane; fall back to primary. */
    uint32_t overlay = 0, primary = 0;
    for (uint32_t i = 0; i < pres->count_planes; i++) {
        drmModePlane *p = drmModeGetPlane(d->fd, pres->planes[i]);
        if (!p) continue;
        if (!(p->possible_crtcs & (1 << crtc_idx))) { drmModeFreePlane(p); continue; }
        /* Query plane type property. */
        drmModeObjectProperties *props = drmModeObjectGetProperties(
            d->fd, p->plane_id, DRM_MODE_OBJECT_PLANE);
        uint64_t type = 0;
        for (uint32_t j = 0; j < props->count_props; j++) {
            drmModePropertyRes *pr = drmModeGetProperty(d->fd, props->props[j]);
            if (pr && strcmp(pr->name, "type") == 0) type = props->prop_values[j];
            if (pr) drmModeFreeProperty(pr);
        }
        drmModeFreeObjectProperties(props);
        if (type == DRM_PLANE_TYPE_PRIMARY) primary = p->plane_id;
        else if (type == DRM_PLANE_TYPE_OVERLAY && !overlay) overlay = p->plane_id;
        drmModeFreePlane(p);
    }
    drmModeFreePlaneResources(pres);
    /* Use overlay plane — primary is owned by fbcon/kernel modesetting.
     * Overlay + NV12 works on VC4; overlay + YU12 (3-plane) gives ENOSPC. */
    d->plane_id = overlay ? overlay : primary;
    if (!d->plane_id) die("no suitable plane");
    info("drm: plane %u (%s)", d->plane_id, overlay ? "overlay" : "primary");
    drmModeFreeResources(res);
    return 0;
}

/* Import a decoder capture buffer as a DRM framebuffer. Caches the fb_id
 * on the v4l2_buf struct so re-showing the same buffer costs nothing. */
static int disp_ensure_fb(struct display *dd, struct v4l2_buf *vb,
                          int w, int h, uint32_t v4l2_fourcc) {
    if (vb->drm_fb_id) return 0;
    uint32_t drm_fourcc = v4l2_to_drm_fourcc(v4l2_fourcc);
    if (!drm_fourcc) { info("unknown fourcc %.4s", (char *)&v4l2_fourcc); return -1; }

    uint32_t gem_handle = 0;
    if (drmPrimeFDToHandle(dd->fd, vb->dmabuf_fd, &gem_handle) < 0) {
        info("PRIME_FD_TO_HANDLE: %s", strerror(errno));
        return -1;
    }
    uint32_t handles[4] = { gem_handle, gem_handle, 0, 0 };
    uint32_t pitches[4] = {0};
    uint32_t offsets[4] = {0};

    /* NV12: Y plane stride = w, UV interleaved stride = w at offset w*h.
     * YU12/YUV420: Y stride = w, U stride = w/2 @ offset w*h, V stride = w/2 @ offset w*h + (w/2 * h/2) */
    if (drm_fourcc == DRM_FORMAT_NV12) {
        pitches[0] = w;
        offsets[0] = 0;
        pitches[1] = w;
        offsets[1] = w * h;
    } else if (drm_fourcc == DRM_FORMAT_YUV420) {
        pitches[0] = w;
        offsets[0] = 0;
        handles[1] = gem_handle;
        pitches[1] = w / 2;
        offsets[1] = w * h;
        handles[2] = gem_handle;
        pitches[2] = w / 2;
        offsets[2] = w * h + (w / 2) * (h / 2);
    }

    if (drmModeAddFB2(dd->fd, w, h, drm_fourcc, handles, pitches, offsets,
                      &vb->drm_fb_id, 0) < 0) {
        info("AddFB2: %s", strerror(errno));
        return -1;
    }
    return 0;
}

static int prop_id(int fd, uint32_t obj_id, uint32_t obj_type, const char *name) {
    drmModeObjectProperties *props = drmModeObjectGetProperties(fd, obj_id, obj_type);
    if (!props) return -1;
    int id = -1;
    for (uint32_t i = 0; i < props->count_props; i++) {
        drmModePropertyRes *p = drmModeGetProperty(fd, props->props[i]);
        if (p && strcmp(p->name, name) == 0) id = p->prop_id;
        if (p) drmModeFreeProperty(p);
        if (id >= 0) break;
    }
    drmModeFreeObjectProperties(props);
    return id;
}

/* Flip HDMI DPMS. on=true drives the signal out; false puts the connected
 * monitor into standby (backlight off). */
static void disp_set_dpms(struct display *dd, bool on) {
    if (!dd->_dpms_prop || dd->dpms_on == on) return;
    uint64_t v = on ? 0 /* DRM_MODE_DPMS_ON */ : 3 /* DRM_MODE_DPMS_OFF */;
    if (drmModeConnectorSetProperty(dd->fd, dd->connector_id, dd->_dpms_prop, v) < 0) {
        info("SetProperty DPMS %s: %s", on ? "ON" : "OFF", strerror(errno));
        return;
    }
    dd->dpms_on = on;
    info("HDMI DPMS %s", on ? "ON" : "OFF");
}

/* One-time setup of the CRTC/connector. We just kick the plane to the right
 * destination rect for each frame via atomic commit in disp_show(). */
static void disp_configure(struct display *dd) {
    int fb_prop = prop_id(dd->fd, dd->plane_id, DRM_MODE_OBJECT_PLANE, "FB_ID");
    int crtc_prop = prop_id(dd->fd, dd->plane_id, DRM_MODE_OBJECT_PLANE, "CRTC_ID");
    if (fb_prop < 0 || crtc_prop < 0) die("plane props missing");

    dd->_fb_prop = fb_prop;
    dd->_crtc_prop = crtc_prop;
    dd->_src_x = prop_id(dd->fd, dd->plane_id, DRM_MODE_OBJECT_PLANE, "SRC_X");
    dd->_src_y = prop_id(dd->fd, dd->plane_id, DRM_MODE_OBJECT_PLANE, "SRC_Y");
    dd->_src_w = prop_id(dd->fd, dd->plane_id, DRM_MODE_OBJECT_PLANE, "SRC_W");
    dd->_src_h = prop_id(dd->fd, dd->plane_id, DRM_MODE_OBJECT_PLANE, "SRC_H");
    dd->_crtc_x = prop_id(dd->fd, dd->plane_id, DRM_MODE_OBJECT_PLANE, "CRTC_X");
    dd->_crtc_y = prop_id(dd->fd, dd->plane_id, DRM_MODE_OBJECT_PLANE, "CRTC_Y");
    dd->_crtc_w = prop_id(dd->fd, dd->plane_id, DRM_MODE_OBJECT_PLANE, "CRTC_W");
    dd->_crtc_h = prop_id(dd->fd, dd->plane_id, DRM_MODE_OBJECT_PLANE, "CRTC_H");

    /* Look up the connector's DPMS property so we can idle the HDMI output. */
    int pid = prop_id(dd->fd, dd->connector_id, DRM_MODE_OBJECT_CONNECTOR, "DPMS");
    dd->_dpms_prop = pid > 0 ? (uint32_t)pid : 0;
    dd->dpms_on = true;  /* assume kernel left it on after modeset */
    if (!dd->_dpms_prop) info("warn: DPMS property not found on connector");
}

/* Display a framebuffer on our plane, scaled to full screen. Uses the legacy
 * drmModeSetPlane ioctl, which is more permissive on VC4 than atomic commit
 * when the CRTC is managed by fbcon/legacy modesetting. */
static int disp_show(struct display *dd, uint32_t fb_id, int src_w, int src_h) {
    int r = drmModeSetPlane(
        dd->fd, dd->plane_id, dd->crtc_id, fb_id, 0,
        /* crtc_x,y,w,h */ 0, 0, dd->screen_w, dd->screen_h,
        /* src_x,y,w,h in 16.16 */ 0, 0, src_w << 16, src_h << 16);
    if (r < 0) { info("SetPlane: %s", strerror(errno)); return -1; }
    return 0;
}

/* -------------------- main loop -------------------- */

struct app {
    struct decoder dec;
    struct display disp;
    struct depay   dep;
    int udp_fd;
    int current_cap_idx;    /* currently displayed capture buffer */
    uint64_t frames_in;
    uint64_t frames_out;
    uint64_t t_last_stats;
    uint64_t t_last_display; /* ms of last successful disp_show */
};

static uint64_t now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static void on_au(const uint8_t *nal, size_t len, void *user) {
    struct app *a = user;
    a->frames_in++;
    dec_queue_bitstream(&a->dec, nal, len);
}

static void handle_decoder(struct app *a) {
    /* Check for SOURCE_CHANGE event to (re)configure capture side. */
    struct v4l2_event ev;
    while (xioctl(a->dec.fd, VIDIOC_DQEVENT, &ev) == 0) {
        if (ev.type == V4L2_EVENT_SOURCE_CHANGE &&
            (ev.u.src_change.changes & V4L2_EVENT_SRC_CH_RESOLUTION)) {
            info("source change -> reconfigure capture");
            if (a->dec.capture_streaming) {
                int t = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
                xioctl(a->dec.fd, VIDIOC_STREAMOFF, &t);
                a->dec.capture_streaming = false;
            }
            dec_setup_capture(&a->dec);
        }
    }

    /* Dequeue a decoded frame (if any). */
    int idx = dec_dequeue_capture(&a->dec);
    if (idx < 0) return;

    a->frames_out++;
    struct v4l2_buf *vb = &a->dec.cap[idx];
    if (disp_ensure_fb(&a->disp, vb, a->dec.cap_width, a->dec.cap_height,
                       a->dec.cap_fourcc) == 0) {
        /* Waking up the HDMI signal before the flip so the first post-idle
         * frame is visible immediately. */
        if (!a->disp.dpms_on) disp_set_dpms(&a->disp, true);
        if (disp_show(&a->disp, vb->drm_fb_id,
                      a->dec.visible_width, a->dec.visible_height) == 0) {
            a->t_last_display = now_ms();
            /* Re-queue the previously-displayed buffer so the decoder can reuse. */
            if (a->current_cap_idx >= 0 && a->current_cap_idx != idx) {
                dec_requeue_capture(&a->dec, a->current_cap_idx);
            }
            a->current_cap_idx = idx;
            return;
        }
    }
    /* If we couldn't show it, re-queue right away so the decoder keeps going. */
    dec_requeue_capture(&a->dec, idx);
}

int main(void) {
    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);

    struct app a = {0};
    a.current_cap_idx = -1;
    a.dep.nal_cap = MAX_NAL_SIZE;
    a.dep.nal = malloc(MAX_NAL_SIZE);
    if (!a.dep.nal) die("malloc");

    /* UDP socket on :5001, large kernel recv buffer. */
    a.udp_fd = socket(AF_INET, SOCK_DGRAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
    if (a.udp_fd < 0) die("socket");
    int on = 1;
    setsockopt(a.udp_fd, SOL_SOCKET, SO_REUSEADDR, &on, sizeof(on));
    int rcvbuf = 4 * 1024 * 1024;
    setsockopt(a.udp_fd, SOL_SOCKET, SO_RCVBUF, &rcvbuf, sizeof(rcvbuf));
    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port = htons(UDP_PORT);
    if (bind(a.udp_fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) die("bind");
    info("listening on udp/%d", UDP_PORT);

    dec_open(&a.dec);
    disp_open(&a.disp);
    disp_configure(&a.disp);

    a.t_last_stats = now_ms();
    uint8_t pkt[MAX_UDP_PKT];
    struct pollfd pfds[2];

    while (!g_stop) {
        pfds[0].fd = a.udp_fd;
        pfds[0].events = POLLIN;
        pfds[1].fd = a.dec.fd;
        pfds[1].events = POLLIN | POLLPRI;  /* POLLIN=decoded frame, PRI=events */
        int r = poll(pfds, 2, 1000);
        if (r < 0 && errno != EINTR) { info("poll: %s", strerror(errno)); break; }

        /* UDP: drain available packets. */
        if (pfds[0].revents & POLLIN) {
            for (;;) {
                ssize_t n = recv(a.udp_fd, pkt, sizeof(pkt), 0);
                if (n < 0) break;
                depay_feed(&a.dep, pkt, (size_t)n, on_au, &a);
            }
        }
        /* Decoder: events + decoded frames. */
        if (pfds[1].revents) handle_decoder(&a);

        /* Stats once a second. */
        uint64_t t = now_ms();

        /* Auto-idle: if no frame has been shown for a while, drop the HDMI
         * signal so the connected monitor enters DPMS standby. The next frame
         * that arrives will bring it back (see handle_decoder). */
        if (a.disp.dpms_on && a.t_last_display != 0 && t - a.t_last_display > 3000) {
            disp_set_dpms(&a.disp, false);
        }

        if (t - a.t_last_stats >= 1000) {
            info("in=%llu out=%llu (%.1f ms period)",
                 (unsigned long long)a.frames_in,
                 (unsigned long long)a.frames_out,
                 (double)(t - a.t_last_stats));
            a.frames_in = 0; a.frames_out = 0;
            a.t_last_stats = t;
        }
    }

    info("shutting down");
    /* Best-effort cleanup; kernel cleans the rest on exit. */
    if (a.dec.capture_streaming) {
        int t = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
        xioctl(a.dec.fd, VIDIOC_STREAMOFF, &t);
    }
    close(a.udp_fd);
    close(a.dec.fd);
    close(a.disp.fd);
    return 0;
}
