// SPDX-License-Identifier: Apache-2.0
/*
 * xt-cluster-shm — minimal AGL Cluster IC stand-in for rpi5.
 *
 * Why this exists:
 *   A cluster stand-in that renders through wl_shm only, with no GPU
 *   involvement. That makes it useful in two situations: bringing a
 *   display path up before the V3D stack is known good, and telling a
 *   compositor problem apart from a GPU problem -- if this renders and an
 *   EGL client does not, the fault is below the compositor.
 *
 *   It was written when EGL clients on this board produced a black window
 *   because vc4_hvs could not take the HVS core clock while the firmware
 *   display driver still held it. The shipping configuration no longer has
 *   that problem (weston runs gl-renderer through Mesa V3D), so this is a
 *   diagnostic tool rather than a workaround.
 *
 * It's intentionally one C file with no dependencies beyond
 * libwayland-client + libcairo — no MainLoop framework,
 * no shaders, no toolkit. The numbers animate purely from the wall
 * clock so the demo also serves as a "the wayland surface is alive"
 * heartbeat.
 *
 *   Speed: 0..180 km/h sweep on a 12 s sine
 *   Trip A:  monotonic, in tenths of a km
 *   Time-of-day clock in the centre
 *
 * Pipeline:
 *   wl_compositor.create_surface
 *     wl_shm pool (double-buffered)
 *       cairo_image_surface_create_for_data(B8G8R8A8)
 *         cairo draw calls
 *     xdg_toplevel + xdg_surface (so desktop-shell places it)
 *
 *   On every frame callback we cairo-render into the next shm buffer,
 *   wl_surface.attach + damage_buffer + commit, request a new frame
 *   callback, repeat.
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#include <math.h>
#include <time.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <linux/memfd.h>
#include <wayland-client.h>
#include <cairo.h>

#include "xdg-shell-client-protocol.h"

/* ----- Wayland globals --------------------------------------------------- */
struct app {
	struct wl_display       *display;
	struct wl_registry      *registry;
	struct wl_compositor    *compositor;
	struct wl_shm           *shm;
	struct xdg_wm_base      *wm_base;

	struct wl_surface       *surface;
	struct xdg_surface      *xdg_surface;
	struct xdg_toplevel     *xdg_toplevel;

	int                      width;
	int                      height;
	bool                     configured;
	bool                     running;

	struct timespec          t0;
	double                   trip_a_km;
};

/* Two shm buffers so we never overwrite a buffer the compositor still
 * holds; we toggle on each frame. */
struct shm_buffer {
	struct wl_buffer *buffer;
	uint8_t          *data;
	int               size;
	bool              busy;
};
#define NUM_BUFFERS 2

/* ----- shm helpers ------------------------------------------------------- */

static int memfd_anon(size_t size)
{
	int fd = syscall(SYS_memfd_create, "xt-cluster", MFD_CLOEXEC);
	if (fd < 0) return -1;
	if (ftruncate(fd, size) < 0) { close(fd); return -1; }
	return fd;
}

static void buffer_release(void *data, struct wl_buffer *wl_buffer)
{
	struct shm_buffer *b = data;
	(void)wl_buffer;
	b->busy = false;
}
static const struct wl_buffer_listener buffer_listener = {
	.release = buffer_release,
};

static int alloc_buffer(struct app *app, struct shm_buffer *b)
{
	int stride = app->width * 4;
	int size   = stride * app->height;
	int fd = memfd_anon(size);
	if (fd < 0) return -1;
	b->data = mmap(NULL, size, PROT_READ|PROT_WRITE, MAP_SHARED, fd, 0);
	if (b->data == MAP_FAILED) { close(fd); return -1; }
	struct wl_shm_pool *pool = wl_shm_create_pool(app->shm, fd, size);
	b->buffer = wl_shm_pool_create_buffer(pool, 0, app->width, app->height,
					      stride, WL_SHM_FORMAT_ARGB8888);
	wl_shm_pool_destroy(pool);
	close(fd);
	wl_buffer_add_listener(b->buffer, &buffer_listener, b);
	b->size = size;
	b->busy = false;
	return 0;
}

/* ----- cairo rendering --------------------------------------------------- */

static double now_seconds(struct app *app)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (ts.tv_sec - app->t0.tv_sec) +
	       (ts.tv_nsec - app->t0.tv_nsec) / 1e9;
}

/* Map t -> 0..1 then to a 0..180 km/h sweep with a sine envelope so it
 * looks like driving instead of a sawtooth. */
static double speed_kmh(double t)
{
	double s = (sin(t * 2.0 * M_PI / 12.0) + 1.0) * 0.5;
	return 90.0 + 80.0 * s; /* 10..170 */
}

static void draw_speedometer(cairo_t *cr, int W, int H,
			     double speed, double trip_km)
{
	/* Background. */
	cairo_set_source_rgb(cr, 0.04, 0.04, 0.06);
	cairo_paint(cr);

	/* Outer ring. */
	double cx = W * 0.5, cy = H * 0.55;
	double r  = (H < W ? H : W) * 0.40;
	cairo_set_line_width(cr, 4.0);
	cairo_set_source_rgb(cr, 0.18, 0.20, 0.26);
	cairo_arc(cr, cx, cy, r, 0, 2 * M_PI);
	cairo_stroke(cr);

	/* Tick marks 0..180 every 20 km/h, sweep over 240 deg. */
	double start = M_PI * (1.0 - 0.667); /* -120 deg from +x, mirrored */
	double sweep = M_PI * 1.333;          /* 240 deg */
	for (int kmh = 0; kmh <= 180; kmh += 10) {
		double frac = kmh / 180.0;
		double a = start + sweep * frac + M_PI / 2.0;
		double r1 = r - 14.0;
		double r2 = (kmh % 20 == 0) ? r - 30.0 : r - 22.0;
		cairo_set_line_width(cr, kmh % 20 == 0 ? 3.0 : 1.5);
		cairo_set_source_rgb(cr, 0.6, 0.7, 0.9);
		cairo_move_to(cr, cx + r1 * cos(a), cy + r1 * sin(a));
		cairo_line_to(cr, cx + r2 * cos(a), cy + r2 * sin(a));
		cairo_stroke(cr);

		if (kmh % 20 == 0) {
			char buf[8];
			snprintf(buf, sizeof(buf), "%d", kmh);
			cairo_set_source_rgb(cr, 0.85, 0.90, 0.95);
			cairo_select_font_face(cr, "sans",
					       CAIRO_FONT_SLANT_NORMAL,
					       CAIRO_FONT_WEIGHT_BOLD);
			cairo_set_font_size(cr, 18);
			cairo_text_extents_t te;
			cairo_text_extents(cr, buf, &te);
			double tr = r - 50.0;
			cairo_move_to(cr,
				      cx + tr * cos(a) - te.width/2 - te.x_bearing,
				      cy + tr * sin(a) - te.height/2 - te.y_bearing);
			cairo_show_text(cr, buf);
		}
	}

	/* Needle. */
	double frac = speed / 180.0;
	if (frac < 0) frac = 0; else if (frac > 1) frac = 1;
	double angle = start + sweep * frac + M_PI / 2.0;
	cairo_set_line_width(cr, 5.0);
	cairo_set_source_rgb(cr, 0.95, 0.20, 0.20);
	cairo_move_to(cr, cx, cy);
	cairo_line_to(cr,
		      cx + (r - 18.0) * cos(angle),
		      cy + (r - 18.0) * sin(angle));
	cairo_stroke(cr);
	cairo_set_source_rgb(cr, 0.95, 0.20, 0.20);
	cairo_arc(cr, cx, cy, 8.0, 0, 2 * M_PI);
	cairo_fill(cr);

	/* Big speed text under the needle. */
	char speedbuf[16];
	snprintf(speedbuf, sizeof(speedbuf), "%3.0f", speed);
	cairo_select_font_face(cr, "sans",
			       CAIRO_FONT_SLANT_NORMAL,
			       CAIRO_FONT_WEIGHT_BOLD);
	cairo_set_font_size(cr, 64);
	cairo_set_source_rgb(cr, 0.95, 0.95, 0.95);
	cairo_text_extents_t te;
	cairo_text_extents(cr, speedbuf, &te);
	cairo_move_to(cr, cx - te.width/2 - te.x_bearing, cy + 10);
	cairo_show_text(cr, speedbuf);
	cairo_set_font_size(cr, 18);
	cairo_set_source_rgb(cr, 0.6, 0.7, 0.85);
	const char *unit = "km/h";
	cairo_text_extents(cr, unit, &te);
	cairo_move_to(cr, cx - te.width/2 - te.x_bearing, cy + 40);
	cairo_show_text(cr, unit);

	/* Trip meter. */
	char trip[32];
	snprintf(trip, sizeof(trip), "TRIP A  %7.1f km", trip_km);
	cairo_set_font_size(cr, 18);
	cairo_set_source_rgb(cr, 0.7, 0.85, 1.0);
	cairo_move_to(cr, 24, H - 24);
	cairo_show_text(cr, trip);

	/* Banner so it's obvious this is the shm-only fallback. */
	cairo_set_font_size(cr, 14);
	cairo_set_source_rgba(cr, 0.6, 0.7, 0.85, 0.7);
	cairo_move_to(cr, 24, 28);
	cairo_show_text(cr, "AGL Cluster IC (shared-memory renderer)");
}

/* ----- frame loop -------------------------------------------------------- */

static struct shm_buffer buffers[NUM_BUFFERS];
static int next_buf = 0;

static void redraw(struct app *app);
static const struct wl_callback_listener frame_listener;

static void frame_done(void *data, struct wl_callback *cb, uint32_t time)
{
	(void)time;
	wl_callback_destroy(cb);
	redraw(data);
}
static const struct wl_callback_listener frame_listener = {
	.done = frame_done,
};

static void redraw(struct app *app)
{
	struct shm_buffer *b = NULL;
	for (int i = 0; i < NUM_BUFFERS; i++) {
		int idx = (next_buf + i) % NUM_BUFFERS;
		if (!buffers[idx].busy) { b = &buffers[idx]; next_buf = (idx + 1) % NUM_BUFFERS; break; }
	}
	if (!b) return; /* both held by compositor; new frame_done will retry */

	double t = now_seconds(app);
	double speed = speed_kmh(t);
	/* speed is km/h, dt approx 1/60 s; convert to km. */
	app->trip_a_km += speed / 60.0 / 3600.0;

	cairo_surface_t *cs = cairo_image_surface_create_for_data(
		b->data, CAIRO_FORMAT_ARGB32, app->width, app->height, app->width * 4);
	cairo_t *cr = cairo_create(cs);
	draw_speedometer(cr, app->width, app->height, speed, app->trip_a_km);
	cairo_destroy(cr);
	cairo_surface_destroy(cs);

	b->busy = true;
	wl_surface_attach(app->surface, b->buffer, 0, 0);
	wl_surface_damage_buffer(app->surface, 0, 0, app->width, app->height);

	struct wl_callback *cb = wl_surface_frame(app->surface);
	wl_callback_add_listener(cb, &frame_listener, app);

	wl_surface_commit(app->surface);
}

/* ----- xdg-shell plumbing ------------------------------------------------ */

static void xdg_surface_configure(void *data, struct xdg_surface *xs, uint32_t serial)
{
	struct app *app = data;
	xdg_surface_ack_configure(xs, serial);
	if (!app->configured) {
		app->configured = true;
		redraw(app);
	}
}
static const struct xdg_surface_listener xdg_surface_listener = {
	.configure = xdg_surface_configure,
};

static void xdg_toplevel_configure(void *data, struct xdg_toplevel *t,
				   int32_t w, int32_t h, struct wl_array *st)
{
	struct app *app = data;
	(void)t; (void)st;
	if (w > 0 && h > 0 && (w != app->width || h != app->height)) {
		app->width = w; app->height = h;
		/* Reallocate buffers at the new size. */
		for (int i = 0; i < NUM_BUFFERS; i++) {
			if (buffers[i].buffer) {
				wl_buffer_destroy(buffers[i].buffer);
				munmap(buffers[i].data, buffers[i].size);
				buffers[i].buffer = NULL;
			}
		}
		for (int i = 0; i < NUM_BUFFERS; i++) alloc_buffer(app, &buffers[i]);
	}
}
static void xdg_toplevel_close(void *data, struct xdg_toplevel *t)
{
	struct app *app = data;
	(void)t;
	app->running = false;
}
static void xdg_toplevel_configure_bounds(void *d, struct xdg_toplevel *t, int32_t w, int32_t h) {(void)d;(void)t;(void)w;(void)h;}
static void xdg_toplevel_wm_capabilities(void *d, struct xdg_toplevel *t, struct wl_array *c) {(void)d;(void)t;(void)c;}
static const struct xdg_toplevel_listener xdg_toplevel_listener = {
	.configure        = xdg_toplevel_configure,
	.close            = xdg_toplevel_close,
	.configure_bounds = xdg_toplevel_configure_bounds,
	.wm_capabilities  = xdg_toplevel_wm_capabilities,
};

static void wm_base_ping(void *data, struct xdg_wm_base *b, uint32_t serial)
{
	(void)data;
	xdg_wm_base_pong(b, serial);
}
static const struct xdg_wm_base_listener wm_base_listener = {
	.ping = wm_base_ping,
};

/* ----- registry --------------------------------------------------------- */

static void registry_global(void *data, struct wl_registry *reg, uint32_t name,
			    const char *interface, uint32_t version)
{
	struct app *app = data;
	(void)version;
	if (!strcmp(interface, "wl_compositor"))
		app->compositor = wl_registry_bind(reg, name, &wl_compositor_interface, 4);
	else if (!strcmp(interface, "wl_shm"))
		app->shm = wl_registry_bind(reg, name, &wl_shm_interface, 1);
	else if (!strcmp(interface, "xdg_wm_base")) {
		app->wm_base = wl_registry_bind(reg, name, &xdg_wm_base_interface, 1);
		xdg_wm_base_add_listener(app->wm_base, &wm_base_listener, app);
	}
}
static void registry_global_remove(void *d, struct wl_registry *r, uint32_t n) {(void)d;(void)r;(void)n;}
static const struct wl_registry_listener registry_listener = {
	.global        = registry_global,
	.global_remove = registry_global_remove,
};

/* ----- main ------------------------------------------------------------- */

int main(int argc, char **argv)
{
	(void)argc; (void)argv;
	struct app app = { .width = 1280, .height = 720, .running = true };
	clock_gettime(CLOCK_MONOTONIC, &app.t0);

	app.display = wl_display_connect(NULL);
	if (!app.display) { fprintf(stderr, "wayland connect failed\n"); return 1; }
	app.registry = wl_display_get_registry(app.display);
	wl_registry_add_listener(app.registry, &registry_listener, &app);
	wl_display_roundtrip(app.display);
	if (!app.compositor || !app.shm || !app.wm_base) {
		fprintf(stderr, "missing globals (compositor/shm/xdg_wm_base)\n");
		return 1;
	}

	app.surface = wl_compositor_create_surface(app.compositor);
	app.xdg_surface = xdg_wm_base_get_xdg_surface(app.wm_base, app.surface);
	xdg_surface_add_listener(app.xdg_surface, &xdg_surface_listener, &app);
	app.xdg_toplevel = xdg_surface_get_toplevel(app.xdg_surface);
	xdg_toplevel_add_listener(app.xdg_toplevel, &xdg_toplevel_listener, &app);
	xdg_toplevel_set_title(app.xdg_toplevel, "AGL Cluster IC (shm)");
	xdg_toplevel_set_app_id(app.xdg_toplevel, "xt-cluster-shm");
	wl_surface_commit(app.surface);

	/* Pre-allocate buffers at the default size; they'll be re-created
	 * on toplevel.configure if the compositor picks a different one. */
	for (int i = 0; i < NUM_BUFFERS; i++) alloc_buffer(&app, &buffers[i]);

	while (app.running && wl_display_dispatch(app.display) != -1) { /* spin */ }

	return 0;
}
