#include "internal.h"

#include <gdk-pixbuf/gdk-pixbuf.h>
#include <glib.h>
#include <librsvg/rsvg.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

static void ss_pdf_set_gerror(SsPdf *pdf, const char *operation, const GError *error) {
    if (error != NULL && error->message != NULL) {
        char message[512];
        g_snprintf(message, sizeof(message), "%s: %s", operation, error->message);
        ss_pdf_set_error(pdf, message);
    } else {
        ss_pdf_set_error(pdf, operation);
    }
}

const char *ss_pdf_librsvg_version_string(void) {
    static char version[32];
    g_snprintf(version, sizeof(version), "%u.%u.%u", rsvg_major_version, rsvg_minor_version, rsvg_micro_version);
    return version;
}

const char *ss_pdf_gdk_pixbuf_version_string(void) {
    return gdk_pixbuf_version;
}

static GdkPixbuf *ss_raster_load_oriented(const char *path) {
    GError *error = NULL;
    GdkPixbuf *source = gdk_pixbuf_new_from_file(path, &error);
    if (source == NULL) {
        if (error != NULL) g_error_free(error);
        return NULL;
    }
    GdkPixbuf *oriented = gdk_pixbuf_apply_embedded_orientation(source);
    g_object_unref(source);
    return oriented;
}

static cairo_surface_t *ss_raster_surface_from_pixbuf(GdkPixbuf *pixbuf) {
    if (pixbuf == NULL || gdk_pixbuf_get_colorspace(pixbuf) != GDK_COLORSPACE_RGB ||
        gdk_pixbuf_get_bits_per_sample(pixbuf) != 8) return NULL;

    const int width = gdk_pixbuf_get_width(pixbuf);
    const int height = gdk_pixbuf_get_height(pixbuf);
    const int channels = gdk_pixbuf_get_n_channels(pixbuf);
    const int source_stride = gdk_pixbuf_get_rowstride(pixbuf);
    const int has_alpha = gdk_pixbuf_get_has_alpha(pixbuf);
    const guchar *source = gdk_pixbuf_read_pixels(pixbuf);
    if (width <= 0 || height <= 0 || source == NULL || (channels != 3 && channels != 4)) return NULL;

    cairo_surface_t *surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, width, height);
    if (surface == NULL || cairo_surface_status(surface) != CAIRO_STATUS_SUCCESS) {
        if (surface != NULL) cairo_surface_destroy(surface);
        return NULL;
    }

    unsigned char *destination = cairo_image_surface_get_data(surface);
    const int destination_stride = cairo_image_surface_get_stride(surface);
    for (int row = 0; row < height; row++) {
        const guchar *source_row = source + row * source_stride;
        uint32_t *destination_row = (uint32_t *)(destination + row * destination_stride);
        for (int column = 0; column < width; column++) {
            const guchar *pixel = source_row + column * channels;
            const uint32_t alpha = has_alpha ? pixel[3] : 255;
            const uint32_t red = (pixel[0] * alpha + 127) / 255;
            const uint32_t green = (pixel[1] * alpha + 127) / 255;
            const uint32_t blue = (pixel[2] * alpha + 127) / 255;
            destination_row[column] = (alpha << 24) | (red << 16) | (green << 8) | blue;
        }
    }
    cairo_surface_mark_dirty(surface);
    return surface;
}

int ss_raster_size(const char *path, double *width, double *height) {
    GdkPixbuf *pixbuf = ss_raster_load_oriented(path);
    if (pixbuf == NULL) return 1;
    const int source_width = gdk_pixbuf_get_width(pixbuf);
    const int source_height = gdk_pixbuf_get_height(pixbuf);
    if (width != NULL) *width = source_width;
    if (height != NULL) *height = source_height;
    g_object_unref(pixbuf);
    return source_width > 0 && source_height > 0 ? 0 : 1;
}

static GdkPixbuf *ss_raster_load_bytes(const unsigned char *bytes, size_t length) {
    if (bytes == NULL || length == 0) return NULL;
    GdkPixbufLoader *loader = gdk_pixbuf_loader_new();
    if (loader == NULL) return NULL;
    GError *error = NULL;
    if (!gdk_pixbuf_loader_write(loader, bytes, length, &error)) {
        if (error != NULL) g_error_free(error);
        g_object_unref(loader);
        return NULL;
    }
    if (!gdk_pixbuf_loader_close(loader, &error)) {
        if (error != NULL) g_error_free(error);
        g_object_unref(loader);
        return NULL;
    }
    GdkPixbuf *pixbuf = gdk_pixbuf_loader_get_pixbuf(loader);
    if (pixbuf != NULL) g_object_ref(pixbuf);
    g_object_unref(loader);
    return pixbuf;
}

int ss_raster_metadata_bytes(const unsigned char *bytes, size_t length, SsRasterMetadata *metadata) {
    if (metadata == NULL) return 1;
    memset(metadata, 0, sizeof(*metadata));
    GdkPixbuf *source = ss_raster_load_bytes(bytes, length);
    if (source == NULL) return 1;
    const int pixel_width = gdk_pixbuf_get_width(source);
    const int pixel_height = gdk_pixbuf_get_height(source);
    const char *orientation_value = gdk_pixbuf_get_option(source, "orientation");
    long orientation = orientation_value == NULL ? 1 : strtol(orientation_value, NULL, 10);
    if (orientation < 1 || orientation > 8) orientation = 1;
    metadata->pixel_width = pixel_width > 0 ? (size_t)pixel_width : 0;
    metadata->pixel_height = pixel_height > 0 ? (size_t)pixel_height : 0;
    metadata->orientation = (int)orientation;
    metadata->has_alpha = gdk_pixbuf_get_has_alpha(source) ? 1 : 0;
    metadata->color_space = gdk_pixbuf_get_option(source, "icc-profile") == NULL ? 1 : 2;

    GdkPixbuf *oriented = gdk_pixbuf_apply_embedded_orientation(source);
    g_object_unref(source);
    if (oriented == NULL) return 1;
    const int oriented_width = gdk_pixbuf_get_width(oriented);
    const int oriented_height = gdk_pixbuf_get_height(oriented);
    metadata->oriented_width = oriented_width > 0 ? (size_t)oriented_width : 0;
    metadata->oriented_height = oriented_height > 0 ? (size_t)oriented_height : 0;
    g_object_unref(oriented);
    return pixel_width > 0 && pixel_height > 0 && oriented_width > 0 && oriented_height > 0 ? 0 : 1;
}

int ss_pdf_draw_raster(SsPdf *pdf, const char *path, double x, double y, double width, double height) {
    cairo_t *cr = ss_pdf_cairo_context(pdf);
    if (cr == NULL) return 1;
    GError *error = NULL;
    GdkPixbuf *source = gdk_pixbuf_new_from_file(path, &error);
    if (source == NULL) {
        ss_pdf_set_gerror(pdf, "could not load raster image", error);
        if (error != NULL) g_error_free(error);
        return 1;
    }
    GdkPixbuf *pixbuf = gdk_pixbuf_apply_embedded_orientation(source);
    g_object_unref(source);
    if (pixbuf == NULL) {
        ss_pdf_set_error(pdf, "could not apply raster image orientation");
        return 1;
    }
    cairo_surface_t *image = ss_raster_surface_from_pixbuf(pixbuf);
    g_object_unref(pixbuf);
    if (image == NULL) {
        ss_pdf_set_error(pdf, "could not create a Cairo raster surface");
        return 1;
    }

    const double source_width = cairo_image_surface_get_width(image);
    const double source_height = cairo_image_surface_get_height(image);
    if (source_width <= 0 || source_height <= 0) {
        cairo_surface_destroy(image);
        ss_pdf_set_error(pdf, "raster image has invalid dimensions");
        return 1;
    }

    cairo_save(cr);
    cairo_translate(cr, x, y);
    cairo_scale(cr, width / source_width, height / source_height);
    cairo_set_source_surface(cr, image, 0, 0);
    cairo_paint(cr);
    cairo_restore(cr);
    cairo_surface_destroy(image);
    if (cairo_status(cr) == CAIRO_STATUS_SUCCESS) return 0;
    ss_pdf_set_error(pdf, cairo_status_to_string(cairo_status(cr)));
    return 1;
}

static int ss_svg_intrinsic_size(RsvgHandle *handle, double *width, double *height) {
    double intrinsic_width = 0;
    double intrinsic_height = 0;
    if (rsvg_handle_get_intrinsic_size_in_pixels(handle, &intrinsic_width, &intrinsic_height) &&
        intrinsic_width > 0 && intrinsic_height > 0) {
        if (width != NULL) *width = intrinsic_width;
        if (height != NULL) *height = intrinsic_height;
        return 0;
    }

    gboolean has_width = FALSE;
    gboolean has_height = FALSE;
    gboolean has_view_box = FALSE;
    RsvgLength width_length;
    RsvgLength height_length;
    RsvgRectangle view_box;
    rsvg_handle_get_intrinsic_dimensions(
        handle,
        &has_width,
        &width_length,
        &has_height,
        &height_length,
        &has_view_box,
        &view_box
    );
    (void)has_width;
    (void)width_length;
    (void)has_height;
    (void)height_length;
    if (!has_view_box || view_box.width <= 0 || view_box.height <= 0) return 1;
    if (width != NULL) *width = view_box.width;
    if (height != NULL) *height = view_box.height;
    return 0;
}

int ss_svg_size(const char *path, double *width, double *height) {
    GError *error = NULL;
    RsvgHandle *handle = rsvg_handle_new_from_file(path, &error);
    if (handle == NULL) {
        if (error != NULL) g_error_free(error);
        return 1;
    }

    const int result = ss_svg_intrinsic_size(handle, width, height);
    g_object_unref(handle);
    return result;
}

int ss_svg_metadata_bytes(const unsigned char *bytes, size_t length, SsSvgMetadata *metadata) {
    if (bytes == NULL || length == 0 || metadata == NULL) return 1;
    memset(metadata, 0, sizeof(*metadata));
    GError *error = NULL;
    RsvgHandle *handle = rsvg_handle_new_from_data(bytes, length, &error);
    if (handle == NULL) {
        if (error != NULL) g_error_free(error);
        return 1;
    }

    if (ss_svg_intrinsic_size(handle, &metadata->width, &metadata->height) != 0) {
        g_object_unref(handle);
        return 1;
    }

    gboolean has_width = FALSE;
    gboolean has_height = FALSE;
    gboolean has_view_box = FALSE;
    RsvgLength intrinsic_width;
    RsvgLength intrinsic_height;
    RsvgRectangle view_box;
    rsvg_handle_get_intrinsic_dimensions(
        handle,
        &has_width,
        &intrinsic_width,
        &has_height,
        &intrinsic_height,
        &has_view_box,
        &view_box
    );
    (void)has_width;
    (void)intrinsic_width;
    (void)has_height;
    (void)intrinsic_height;
    metadata->has_view_box = has_view_box ? 1 : 0;
    if (has_view_box) {
        metadata->view_box_x = view_box.x;
        metadata->view_box_y = view_box.y;
        metadata->view_box_width = view_box.width;
        metadata->view_box_height = view_box.height;
    }
    g_object_unref(handle);
    return 0;
}

int ss_pdf_draw_svg(SsPdf *pdf, const char *path, double x, double y, double width, double height) {
    cairo_t *cr = ss_pdf_cairo_context(pdf);
    if (cr == NULL) return 1;

    GError *error = NULL;
    RsvgHandle *handle = rsvg_handle_new_from_file(path, &error);
    if (handle == NULL) {
        ss_pdf_set_gerror(pdf, "could not load SVG image", error);
        if (error != NULL) g_error_free(error);
        return 1;
    }

    RsvgRectangle viewport = {x, y, width, height};
    GError *render_error = NULL;
    cairo_save(cr);
    gboolean ok = rsvg_handle_render_document(handle, cr, &viewport, &render_error);
    cairo_restore(cr);
    g_object_unref(handle);
    if (!ok) ss_pdf_set_gerror(pdf, "could not render SVG image", render_error);
    if (render_error != NULL) g_error_free(render_error);
    if (!ok) return 1;
    if (cairo_status(cr) == CAIRO_STATUS_SUCCESS) return 0;
    ss_pdf_set_error(pdf, cairo_status_to_string(cairo_status(cr)));
    return 1;
}

int ss_pdf_draw_svg_tinted(SsPdf *pdf, const char *path, double x, double y, double width, double height, double r, double g, double b) {
    cairo_t *cr = ss_pdf_cairo_context(pdf);
    if (cr == NULL) return 1;

    GError *error = NULL;
    RsvgHandle *handle = rsvg_handle_new_from_file(path, &error);
    if (handle == NULL) {
        ss_pdf_set_gerror(pdf, "could not load SVG image", error);
        if (error != NULL) g_error_free(error);
        return 1;
    }

    RsvgRectangle viewport = {x, y, width, height};
    GError *render_error = NULL;
    cairo_save(cr);
    cairo_push_group(cr);
    gboolean ok = rsvg_handle_render_document(handle, cr, &viewport, &render_error);
    cairo_pattern_t *mask = cairo_pop_group(cr);
    if (ok) {
        cairo_set_source_rgb(cr, r, g, b);
        cairo_mask(cr, mask);
    }
    cairo_pattern_destroy(mask);
    cairo_restore(cr);
    g_object_unref(handle);
    if (!ok) ss_pdf_set_gerror(pdf, "could not render tinted SVG image", render_error);
    if (render_error != NULL) g_error_free(render_error);
    if (!ok) return 1;
    if (cairo_status(cr) == CAIRO_STATUS_SUCCESS) return 0;
    ss_pdf_set_error(pdf, cairo_status_to_string(cairo_status(cr)));
    return 1;
}
