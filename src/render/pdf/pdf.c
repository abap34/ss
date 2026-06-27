#include "pdf.h"

#include <cairo-pdf.h>
#include <cairo.h>
#include <fontconfig/fontconfig.h>
#include <glib.h>
#include <hb.h>
#include <librsvg/rsvg.h>
#include <pango/pangocairo.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define SS_PI 3.14159265358979323846

typedef struct SsPdfMeasurementFrame {
    cairo_surface_t *surface;
    cairo_t *cr;
    cairo_t *saved_cr;
    struct SsPdfMeasurementFrame *previous;
} SsPdfMeasurementFrame;

struct SsPdf {
    cairo_surface_t *surface;
    cairo_t *pdf_cr;
    cairo_t *cr;
    cairo_surface_t *recording_surface;
    cairo_t *recording_cr;
    SsPdfMeasurementFrame *measurement;
};

static void ss_pdf_destroy_measurements(SsPdf *pdf) {
    if (pdf == NULL) return;
    while (pdf->measurement != NULL) {
        SsPdfMeasurementFrame *frame = pdf->measurement;
        pdf->measurement = frame->previous;
        if (frame->cr != NULL) cairo_destroy(frame->cr);
        if (frame->surface != NULL) cairo_surface_destroy(frame->surface);
        pdf->cr = frame->saved_cr;
        free(frame);
    }
}

static void ss_pdf_destroy_recording(SsPdf *pdf) {
    if (pdf == NULL) return;
    if (pdf->recording_cr != NULL) {
        cairo_destroy(pdf->recording_cr);
        pdf->recording_cr = NULL;
    }
    if (pdf->recording_surface != NULL) {
        cairo_surface_destroy(pdf->recording_surface);
        pdf->recording_surface = NULL;
    }
    pdf->cr = pdf->pdf_cr;
}

static int ss_pdf_recording_surface_ink_extents(cairo_surface_t *surface, SsPdfRecordingExtents *extents) {
    if (surface == NULL || extents == NULL) return 1;
    cairo_recording_surface_ink_extents(
        surface,
        &extents->x,
        &extents->y,
        &extents->width,
        &extents->height
    );
    return cairo_surface_status(surface) == CAIRO_STATUS_SUCCESS ? 0 : 1;
}

static void ss_pdf_set_rgb(double r, double g, double b, cairo_t *cr) {
    cairo_set_source_rgb(cr, r, g, b);
}

const char *ss_pdf_cairo_version_string(void) {
    return cairo_version_string();
}

const char *ss_pdf_pango_version_string(void) {
    return pango_version_string();
}

const char *ss_pdf_librsvg_version_string(void) {
    static char version[32];
    snprintf(version, sizeof(version), "%u.%u.%u", rsvg_major_version, rsvg_minor_version, rsvg_micro_version);
    return version;
}

int ss_pdf_fontconfig_version(void) {
    return FcGetVersion();
}

const char *ss_pdf_harfbuzz_version_string(void) {
    return hb_version_string();
}

static void ss_pdf_rounded_rect_path(cairo_t *cr, double x, double y, double width, double height, double radius) {
    if (width < 0) width = 0;
    if (height < 0) height = 0;
    if (radius < 0) radius = 0;
    if (radius > width / 2.0) radius = width / 2.0;
    if (radius > height / 2.0) radius = height / 2.0;
    if (radius <= 0) {
        cairo_rectangle(cr, x, y, width, height);
        return;
    }

    cairo_new_sub_path(cr);
    cairo_arc(cr, x + width - radius, y + radius, radius, -SS_PI / 2.0, 0);
    cairo_arc(cr, x + width - radius, y + height - radius, radius, 0, SS_PI / 2.0);
    cairo_arc(cr, x + radius, y + height - radius, radius, SS_PI / 2.0, SS_PI);
    cairo_arc(cr, x + radius, y + radius, radius, SS_PI, SS_PI * 1.5);
    cairo_close_path(cr);
}

static char *ss_pdf_escape_tag_string(const char *value) {
    if (value == NULL) return NULL;
    size_t extra = 0;
    for (const char *p = value; *p != '\0'; p++) {
        if (*p == '\'' || *p == '\\') extra++;
    }

    const size_t len = strlen(value);
    char *escaped = (char *)malloc(len + extra + 1);
    if (escaped == NULL) return NULL;

    char *out = escaped;
    for (const char *p = value; *p != '\0'; p++) {
        if (*p == '\'' || *p == '\\') *out++ = '\\';
        *out++ = *p;
    }
    *out = '\0';
    return escaped;
}

static char *ss_pdf_link_attributes(
    double x,
    double y,
    double width,
    double height,
    const char *key,
    const char *value,
    const char *suffix
) {
    char *escaped = ss_pdf_escape_tag_string(value);
    if (escaped == NULL) return NULL;
    if (suffix == NULL) suffix = "";
    const int len = snprintf(
        NULL,
        0,
        "rect=[%.17g %.17g %.17g %.17g] %s='%s'%s",
        x,
        y,
        width,
        height,
        key,
        escaped,
        suffix
    );
    if (len < 0) {
        free(escaped);
        return NULL;
    }
    char *attributes = (char *)malloc((size_t)len + 1);
    if (attributes == NULL) {
        free(escaped);
        return NULL;
    }
    snprintf(
        attributes,
        (size_t)len + 1,
        "rect=[%.17g %.17g %.17g %.17g] %s='%s'%s",
        x,
        y,
        width,
        height,
        key,
        escaped,
        suffix
    );
    free(escaped);
    return attributes;
}

static int ss_pdf_begin_link(SsPdf *pdf, double x, double y, double width, double height, const char *key, const char *value, const char *suffix) {
    if (pdf == NULL || pdf->cr == NULL || value == NULL) return 1;
    char *attributes = ss_pdf_link_attributes(x, y, width, height, key, value, suffix);
    if (attributes == NULL) return 1;
    cairo_tag_begin(pdf->cr, CAIRO_TAG_LINK, attributes);
    free(attributes);
    return cairo_status(pdf->cr) == CAIRO_STATUS_SUCCESS ? 0 : 1;
}

SsPdf *ss_pdf_create(const char *path, double width, double height) {
    SsPdf *pdf = (SsPdf *)calloc(1, sizeof(SsPdf));
    if (pdf == NULL) return NULL;

    pdf->surface = cairo_pdf_surface_create(path, width, height);
    if (pdf->surface == NULL || cairo_surface_status(pdf->surface) != CAIRO_STATUS_SUCCESS) {
        ss_pdf_destroy(pdf);
        return NULL;
    }

    pdf->pdf_cr = cairo_create(pdf->surface);
    pdf->cr = pdf->pdf_cr;
    if (pdf->pdf_cr == NULL || cairo_status(pdf->pdf_cr) != CAIRO_STATUS_SUCCESS) {
        ss_pdf_destroy(pdf);
        return NULL;
    }

    return pdf;
}

void ss_pdf_destroy(SsPdf *pdf) {
    if (pdf == NULL) return;
    ss_pdf_destroy_measurements(pdf);
    ss_pdf_destroy_recording(pdf);
    if (pdf->pdf_cr != NULL) cairo_destroy(pdf->pdf_cr);
    if (pdf->surface != NULL) cairo_surface_destroy(pdf->surface);
    free(pdf);
}

void ss_pdf_set_creator(SsPdf *pdf, const char *creator) {
    if (pdf == NULL || pdf->surface == NULL) return;
    cairo_pdf_surface_set_metadata(pdf->surface, CAIRO_PDF_METADATA_CREATOR, creator);
}

void ss_pdf_begin_page(SsPdf *pdf, double width, double height) {
    if (pdf == NULL || pdf->surface == NULL) return;
    cairo_pdf_surface_set_size(pdf->surface, width, height);
}

void ss_pdf_end_page(SsPdf *pdf) {
    if (pdf == NULL || pdf->cr == NULL) return;
    cairo_show_page(pdf->cr);
}

int ss_pdf_finish(SsPdf *pdf) {
    if (pdf == NULL || pdf->surface == NULL || pdf->pdf_cr == NULL || pdf->recording_surface != NULL || pdf->measurement != NULL) return 1;
    cairo_surface_finish(pdf->surface);
    if (cairo_status(pdf->pdf_cr) != CAIRO_STATUS_SUCCESS) return 1;
    if (cairo_surface_status(pdf->surface) != CAIRO_STATUS_SUCCESS) return 1;
    return 0;
}

int ss_pdf_begin_recording(SsPdf *pdf) {
    if (pdf == NULL || pdf->pdf_cr == NULL || pdf->recording_surface != NULL) return 1;
    pdf->recording_surface = cairo_recording_surface_create(CAIRO_CONTENT_COLOR_ALPHA, NULL);
    if (pdf->recording_surface == NULL || cairo_surface_status(pdf->recording_surface) != CAIRO_STATUS_SUCCESS) {
        ss_pdf_destroy_recording(pdf);
        return 1;
    }
    pdf->recording_cr = cairo_create(pdf->recording_surface);
    if (pdf->recording_cr == NULL || cairo_status(pdf->recording_cr) != CAIRO_STATUS_SUCCESS) {
        ss_pdf_destroy_recording(pdf);
        return 1;
    }
    pdf->cr = pdf->recording_cr;
    return 0;
}

int ss_pdf_recording_ink_extents(SsPdf *pdf, SsPdfRecordingExtents *extents) {
    if (pdf == NULL || pdf->recording_surface == NULL || extents == NULL) return 1;
    return ss_pdf_recording_surface_ink_extents(pdf->recording_surface, extents);
}

int ss_pdf_recording_fit(SsPdf *pdf, double page_width, double page_height, double margin, SsPdfRecordingFit *fit) {
    if (pdf == NULL || pdf->recording_surface == NULL || fit == NULL) return 1;
    if (margin < 0) margin = 0;

    SsPdfRecordingExtents extents = {0};
    if (ss_pdf_recording_ink_extents(pdf, &extents) != 0) return 1;

    if (extents.width <= 0 || extents.height <= 0) {
        fit->bounds = extents;
        fit->scale = 1.0;
        fit->tx = 0.0;
        fit->ty = 0.0;
        return 0;
    }

    const double pad = 1.0;
    double x = extents.x - pad;
    double y = extents.y - pad;
    double width = extents.width + pad * 2.0;
    double height = extents.height + pad * 2.0;

    const double available_width = page_width - margin * 2.0;
    const double available_height = page_height - margin * 2.0;
    if (available_width <= 0 || available_height <= 0) return 1;

    double scale = 1.0;
    if (width > available_width || height > available_height) {
        const double scale_x = available_width / width;
        const double scale_y = available_height / height;
        scale = scale_x < scale_y ? scale_x : scale_y;
        if (scale <= 0) return 1;
    }

    double tx = 0.0;
    double ty = 0.0;
    if (scale < 1.0) {
        tx = margin + (available_width - width * scale) / 2.0 - x * scale;
        ty = margin + (available_height - height * scale) / 2.0 - y * scale;
    } else {
        const double min_tx = margin - x;
        const double max_tx = page_width - margin - (x + width);
        const double min_ty = margin - y;
        const double max_ty = page_height - margin - (y + height);
        if (min_tx > 0.0) tx = min_tx;
        if (max_tx < 0.0 && (tx == 0.0 || max_tx > tx)) tx = max_tx;
        if (min_ty > 0.0) ty = min_ty;
        if (max_ty < 0.0 && (ty == 0.0 || max_ty > ty)) ty = max_ty;
    }

    fit->bounds.x = x;
    fit->bounds.y = y;
    fit->bounds.width = width;
    fit->bounds.height = height;
    fit->scale = scale;
    fit->tx = tx;
    fit->ty = ty;
    return 0;
}

int ss_pdf_paint_recording_with_fit(SsPdf *pdf, const SsPdfRecordingFit *fit) {
    if (pdf == NULL || pdf->pdf_cr == NULL || pdf->recording_surface == NULL || fit == NULL) return 1;

    cairo_t *recording_cr = pdf->recording_cr;
    pdf->recording_cr = NULL;
    if (recording_cr != NULL) cairo_destroy(recording_cr);
    pdf->cr = pdf->pdf_cr;

    if (fit->bounds.width <= 0 || fit->bounds.height <= 0) {
        ss_pdf_destroy_recording(pdf);
        return 0;
    }

    cairo_save(pdf->pdf_cr);
    cairo_translate(pdf->pdf_cr, fit->tx, fit->ty);
    cairo_scale(pdf->pdf_cr, fit->scale, fit->scale);
    cairo_set_source_surface(pdf->pdf_cr, pdf->recording_surface, 0, 0);
    cairo_paint(pdf->pdf_cr);
    cairo_restore(pdf->pdf_cr);

    const int ok = cairo_status(pdf->pdf_cr) == CAIRO_STATUS_SUCCESS ? 0 : 1;
    ss_pdf_destroy_recording(pdf);
    return ok;
}

int ss_pdf_paint_recording_fit(SsPdf *pdf, double page_width, double page_height, double margin) {
    if (pdf == NULL || pdf->pdf_cr == NULL || pdf->recording_surface == NULL) return 1;

    SsPdfRecordingFit fit = {0};
    if (ss_pdf_recording_fit(pdf, page_width, page_height, margin, &fit) != 0) return 1;
    return ss_pdf_paint_recording_with_fit(pdf, &fit);
}

int ss_pdf_begin_measurement(SsPdf *pdf) {
    if (pdf == NULL || pdf->cr == NULL) return 1;

    SsPdfMeasurementFrame *frame = (SsPdfMeasurementFrame *)calloc(1, sizeof(SsPdfMeasurementFrame));
    if (frame == NULL) return 1;

    frame->surface = cairo_recording_surface_create(CAIRO_CONTENT_COLOR_ALPHA, NULL);
    if (frame->surface == NULL || cairo_surface_status(frame->surface) != CAIRO_STATUS_SUCCESS) {
        if (frame->surface != NULL) cairo_surface_destroy(frame->surface);
        free(frame);
        return 1;
    }

    frame->cr = cairo_create(frame->surface);
    if (frame->cr == NULL || cairo_status(frame->cr) != CAIRO_STATUS_SUCCESS) {
        if (frame->cr != NULL) cairo_destroy(frame->cr);
        cairo_surface_destroy(frame->surface);
        free(frame);
        return 1;
    }

    frame->saved_cr = pdf->cr;
    frame->previous = pdf->measurement;
    pdf->measurement = frame;
    pdf->cr = frame->cr;
    return 0;
}

int ss_pdf_measurement_ink_extents(SsPdf *pdf, SsPdfRecordingExtents *extents) {
    if (pdf == NULL || pdf->measurement == NULL || extents == NULL) return 1;
    return ss_pdf_recording_surface_ink_extents(pdf->measurement->surface, extents);
}

int ss_pdf_end_measurement(SsPdf *pdf) {
    if (pdf == NULL || pdf->measurement == NULL) return 1;
    SsPdfMeasurementFrame *frame = pdf->measurement;
    pdf->measurement = frame->previous;
    pdf->cr = frame->saved_cr;
    const int ok =
        cairo_status(frame->cr) == CAIRO_STATUS_SUCCESS &&
        cairo_surface_status(frame->surface) == CAIRO_STATUS_SUCCESS;
    cairo_destroy(frame->cr);
    cairo_surface_destroy(frame->surface);
    free(frame);
    return ok ? 0 : 1;
}

void ss_pdf_fill_rect(SsPdf *pdf, double x, double y, double width, double height, double r, double g, double b) {
    if (pdf == NULL || pdf->cr == NULL) return;
    ss_pdf_set_rgb(r, g, b, pdf->cr);
    cairo_rectangle(pdf->cr, x, y, width, height);
    cairo_fill(pdf->cr);
}

void ss_pdf_stroke_line(
    SsPdf *pdf,
    double x1,
    double y1,
    double x2,
    double y2,
    double line_width,
    double r,
    double g,
    double b,
    double dash_on,
    double dash_off
) {
    if (pdf == NULL || pdf->cr == NULL) return;
    ss_pdf_set_rgb(r, g, b, pdf->cr);
    cairo_set_line_width(pdf->cr, line_width);
    if (dash_on > 0 && dash_off > 0) {
        double dashes[2] = { dash_on, dash_off };
        cairo_set_dash(pdf->cr, dashes, 2, 0);
    }
    cairo_move_to(pdf->cr, x1, y1);
    cairo_line_to(pdf->cr, x2, y2);
    cairo_stroke(pdf->cr);
    cairo_set_dash(pdf->cr, NULL, 0, 0);
}

void ss_pdf_fill_stroke_rounded_rect(
    SsPdf *pdf,
    double x,
    double y,
    double width,
    double height,
    double radius,
    int has_fill,
    double fill_r,
    double fill_g,
    double fill_b,
    int has_stroke,
    double stroke_r,
    double stroke_g,
    double stroke_b,
    double line_width
) {
    if (pdf == NULL || pdf->cr == NULL) return;
    ss_pdf_rounded_rect_path(pdf->cr, x, y, width, height, radius);
    if (has_fill) {
        ss_pdf_set_rgb(fill_r, fill_g, fill_b, pdf->cr);
        if (has_stroke) {
            cairo_fill_preserve(pdf->cr);
        } else {
            cairo_fill(pdf->cr);
        }
    }
    if (has_stroke) {
        ss_pdf_set_rgb(stroke_r, stroke_g, stroke_b, pdf->cr);
        cairo_set_line_width(pdf->cr, line_width);
        cairo_stroke(pdf->cr);
    }
}

int ss_pdf_begin_uri_link(SsPdf *pdf, double x, double y, double width, double height, const char *uri) {
    return ss_pdf_begin_link(pdf, x, y, width, height, "uri", uri, "");
}

int ss_pdf_begin_dest_link(SsPdf *pdf, double x, double y, double width, double height, const char *dest) {
    return ss_pdf_begin_link(pdf, x, y, width, height, "dest", dest, "");
}

void ss_pdf_end_link(SsPdf *pdf) {
    if (pdf == NULL || pdf->cr == NULL) return;
    cairo_tag_end(pdf->cr, CAIRO_TAG_LINK);
}

int ss_pdf_add_destination(SsPdf *pdf, const char *name, double x, double y) {
    if (pdf == NULL || pdf->cr == NULL || name == NULL) return 1;
    char *escaped = ss_pdf_escape_tag_string(name);
    if (escaped == NULL) return 1;
    const int len = snprintf(NULL, 0, "name='%s' x=%.17g y=%.17g", escaped, x, y);
    if (len < 0) {
        free(escaped);
        return 1;
    }
    char *attributes = (char *)malloc((size_t)len + 1);
    if (attributes == NULL) {
        free(escaped);
        return 1;
    }
    snprintf(attributes, (size_t)len + 1, "name='%s' x=%.17g y=%.17g", escaped, x, y);
    cairo_tag_begin(pdf->cr, CAIRO_TAG_DEST, attributes);
    cairo_tag_end(pdf->cr, CAIRO_TAG_DEST);
    free(attributes);
    free(escaped);
    return cairo_status(pdf->cr) == CAIRO_STATUS_SUCCESS ? 0 : 1;
}

static PangoStyle ss_pango_style(int style) {
    switch (style) {
        case 1: return PANGO_STYLE_OBLIQUE;
        case 2: return PANGO_STYLE_ITALIC;
        default: return PANGO_STYLE_NORMAL;
    }
}

static PangoStretch ss_pango_stretch(int stretch) {
    switch (stretch) {
        case 0: return PANGO_STRETCH_ULTRA_CONDENSED;
        case 1: return PANGO_STRETCH_EXTRA_CONDENSED;
        case 2: return PANGO_STRETCH_CONDENSED;
        case 3: return PANGO_STRETCH_SEMI_CONDENSED;
        case 5: return PANGO_STRETCH_SEMI_EXPANDED;
        case 6: return PANGO_STRETCH_EXPANDED;
        case 7: return PANGO_STRETCH_EXTRA_EXPANDED;
        case 8: return PANGO_STRETCH_ULTRA_EXPANDED;
        default: return PANGO_STRETCH_NORMAL;
    }
}

static PangoFontDescription *ss_font_description(const char *family, int weight, int style, int stretch, double font_size) {
    PangoFontDescription *desc = pango_font_description_new();
    if (desc == NULL) return NULL;
    const char *resolved_family = (family != NULL && family[0] != '\0') ? family : "sans-serif";
    int resolved_weight = weight;
    if (resolved_weight < 1) resolved_weight = 1;
    if (resolved_weight > 1000) resolved_weight = 1000;
    pango_font_description_set_family(desc, resolved_family);
    pango_font_description_set_weight(desc, (PangoWeight)resolved_weight);
    pango_font_description_set_style(desc, ss_pango_style(style));
    pango_font_description_set_stretch(desc, ss_pango_stretch(stretch));
    pango_font_description_set_absolute_size(desc, font_size * PANGO_SCALE);
    return desc;
}

int ss_pdf_draw_text(
    SsPdf *pdf,
    double x,
    double y,
    double width,
    double height,
    const char *text,
    const char *font_family,
    int font_weight,
    int font_style,
    int font_stretch,
    double font_size,
    double r,
    double g,
    double b,
    int wrap
) {
    if (pdf == NULL || pdf->cr == NULL) return 1;

    PangoLayout *layout = pango_cairo_create_layout(pdf->cr);
    if (layout == NULL) return 1;

    PangoFontDescription *desc = ss_font_description(font_family, font_weight, font_style, font_stretch, font_size);
    if (desc == NULL) {
        g_object_unref(layout);
        return 1;
    }
    pango_layout_set_font_description(layout, desc);
    pango_font_description_free(desc);

    char *valid_text = g_utf8_make_valid(text, -1);
    if (valid_text == NULL) {
        g_object_unref(layout);
        return 1;
    }
    pango_layout_set_text(layout, valid_text, -1);
    g_free(valid_text);
    if (wrap && width > 0) {
        pango_layout_set_width(layout, (int)(width * PANGO_SCALE));
        pango_layout_set_wrap(layout, PANGO_WRAP_WORD_CHAR);
    } else {
        pango_layout_set_width(layout, -1);
    }
    (void)height;

    cairo_save(pdf->cr);
    ss_pdf_set_rgb(r, g, b, pdf->cr);
    cairo_move_to(pdf->cr, x, y);
    pango_cairo_layout_path(pdf->cr, layout);
    cairo_fill(pdf->cr);
    cairo_restore(pdf->cr);

    g_object_unref(layout);
    return cairo_status(pdf->cr) == CAIRO_STATUS_SUCCESS ? 0 : 1;
}

int ss_pdf_draw_text_baseline(
    SsPdf *pdf,
    double x,
    double baseline_y,
    double clip_y,
    double width,
    double height,
    const char *text,
    const char *font_family,
    int font_weight,
    int font_style,
    int font_stretch,
    double font_size,
    double r,
    double g,
    double b,
    int wrap
) {
    if (pdf == NULL || pdf->cr == NULL) return 1;

    PangoLayout *layout = pango_cairo_create_layout(pdf->cr);
    if (layout == NULL) return 1;

    PangoFontDescription *desc = ss_font_description(font_family, font_weight, font_style, font_stretch, font_size);
    if (desc == NULL) {
        g_object_unref(layout);
        return 1;
    }
    pango_layout_set_font_description(layout, desc);
    pango_font_description_free(desc);

    char *valid_text = g_utf8_make_valid(text, -1);
    if (valid_text == NULL) {
        g_object_unref(layout);
        return 1;
    }
    pango_layout_set_text(layout, valid_text, -1);
    g_free(valid_text);
    if (wrap && width > 0) {
        pango_layout_set_width(layout, (int)(width * PANGO_SCALE));
        pango_layout_set_wrap(layout, PANGO_WRAP_WORD_CHAR);
    } else {
        pango_layout_set_width(layout, -1);
    }
    (void)height;
    (void)clip_y;

    double layout_y = baseline_y - ((double)pango_layout_get_baseline(layout)) / PANGO_SCALE;
    cairo_save(pdf->cr);
    ss_pdf_set_rgb(r, g, b, pdf->cr);
    cairo_move_to(pdf->cr, x, layout_y);
    pango_cairo_layout_path(pdf->cr, layout);
    cairo_fill(pdf->cr);
    cairo_restore(pdf->cr);

    g_object_unref(layout);
    return cairo_status(pdf->cr) == CAIRO_STATUS_SUCCESS ? 0 : 1;
}

int ss_pdf_draw_color_text_baseline(
    SsPdf *pdf,
    double x,
    double baseline_y,
    double clip_y,
    double width,
    double height,
    const char *text,
    const char *font_family,
    int font_weight,
    int font_style,
    int font_stretch,
    double font_size,
    double r,
    double g,
    double b,
    int wrap
) {
    if (pdf == NULL || pdf->cr == NULL) return 1;

    PangoLayout *layout = pango_cairo_create_layout(pdf->cr);
    if (layout == NULL) return 1;

    PangoFontDescription *desc = ss_font_description(font_family, font_weight, font_style, font_stretch, font_size);
    if (desc == NULL) {
        g_object_unref(layout);
        return 1;
    }
    pango_layout_set_font_description(layout, desc);
    pango_font_description_free(desc);

    char *valid_text = g_utf8_make_valid(text, -1);
    if (valid_text == NULL) {
        g_object_unref(layout);
        return 1;
    }
    pango_layout_set_text(layout, valid_text, -1);
    g_free(valid_text);
    if (wrap && width > 0) {
        pango_layout_set_width(layout, (int)(width * PANGO_SCALE));
        pango_layout_set_wrap(layout, PANGO_WRAP_WORD_CHAR);
    } else {
        pango_layout_set_width(layout, -1);
    }
    (void)height;
    (void)clip_y;

    double layout_y = baseline_y - ((double)pango_layout_get_baseline(layout)) / PANGO_SCALE;
    cairo_save(pdf->cr);
    ss_pdf_set_rgb(r, g, b, pdf->cr);
    cairo_move_to(pdf->cr, x, layout_y);
    pango_cairo_show_layout(pdf->cr, layout);
    cairo_restore(pdf->cr);

    g_object_unref(layout);
    return cairo_status(pdf->cr) == CAIRO_STATUS_SUCCESS ? 0 : 1;
}

static double ss_measure_text_on_cairo(cairo_t *cr, const char *text, const char *font_family, int font_weight, int font_style, int font_stretch, double font_size, int visual_width) {
    if (cr == NULL) return 0.0;

    PangoLayout *layout = pango_cairo_create_layout(cr);
    if (layout == NULL) return 0.0;

    PangoFontDescription *desc = ss_font_description(font_family, font_weight, font_style, font_stretch, font_size);
    if (desc == NULL) {
        g_object_unref(layout);
        return 0.0;
    }
    pango_layout_set_font_description(layout, desc);
    pango_font_description_free(desc);
    char *valid_text = g_utf8_make_valid(text, -1);
    if (valid_text == NULL) {
        g_object_unref(layout);
        return 0.0;
    }
    pango_layout_set_text(layout, valid_text, -1);
    g_free(valid_text);

    if (visual_width) {
        PangoRectangle ink = {0};
        PangoRectangle logical = {0};
        pango_layout_get_extents(layout, &ink, &logical);
        g_object_unref(layout);

        const double logical_width = ((double)logical.width) / PANGO_SCALE;
        const double ink_right = ((double)(ink.x + ink.width)) / PANGO_SCALE;
        return ink_right > logical_width ? ink_right : logical_width;
    }

    int width = 0;
    int height = 0;
    pango_layout_get_size(layout, &width, &height);
    g_object_unref(layout);
    return ((double)width) / PANGO_SCALE;
}

static cairo_t *ss_text_measure_context(void) {
    static cairo_surface_t *surface = NULL;
    static cairo_t *cr = NULL;

    if (cr != NULL && cairo_status(cr) == CAIRO_STATUS_SUCCESS) return cr;
    if (cr != NULL) {
        cairo_destroy(cr);
        cr = NULL;
    }
    if (surface != NULL) {
        cairo_surface_destroy(surface);
        surface = NULL;
    }

    surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, 1, 1);
    if (surface == NULL || cairo_surface_status(surface) != CAIRO_STATUS_SUCCESS) {
        if (surface != NULL) {
            cairo_surface_destroy(surface);
            surface = NULL;
        }
        return NULL;
    }

    cr = cairo_create(surface);
    if (cr == NULL || cairo_status(cr) != CAIRO_STATUS_SUCCESS) {
        if (cr != NULL) {
            cairo_destroy(cr);
            cr = NULL;
        }
        cairo_surface_destroy(surface);
        surface = NULL;
        return NULL;
    }
    return cr;
}

double ss_pdf_measure_text(SsPdf *pdf, const char *text, const char *font_family, int font_weight, int font_style, int font_stretch, double font_size) {
    if (pdf == NULL || pdf->cr == NULL) return 0.0;
    return ss_measure_text_on_cairo(pdf->cr, text, font_family, font_weight, font_style, font_stretch, font_size, 0);
}

double ss_pdf_measure_text_visual_width(SsPdf *pdf, const char *text, const char *font_family, int font_weight, int font_style, int font_stretch, double font_size) {
    if (pdf == NULL || pdf->cr == NULL) return 0.0;
    return ss_measure_text_on_cairo(pdf->cr, text, font_family, font_weight, font_style, font_stretch, font_size, 1);
}

double ss_text_measure_text(const char *text, const char *font_family, int font_weight, int font_style, int font_stretch, double font_size) {
    static GMutex measure_mutex;
    g_mutex_lock(&measure_mutex);
    const double width = ss_measure_text_on_cairo(ss_text_measure_context(), text, font_family, font_weight, font_style, font_stretch, font_size, 0);
    g_mutex_unlock(&measure_mutex);
    return width;
}

double ss_text_measure_text_visual_width(const char *text, const char *font_family, int font_weight, int font_style, int font_stretch, double font_size) {
    static GMutex measure_mutex;
    g_mutex_lock(&measure_mutex);
    const double width = ss_measure_text_on_cairo(ss_text_measure_context(), text, font_family, font_weight, font_style, font_stretch, font_size, 1);
    g_mutex_unlock(&measure_mutex);
    return width;
}

int ss_png_size(const char *path, double *width, double *height) {
    cairo_surface_t *surface = cairo_image_surface_create_from_png(path);
    if (surface == NULL || cairo_surface_status(surface) != CAIRO_STATUS_SUCCESS) {
        if (surface != NULL) cairo_surface_destroy(surface);
        return 1;
    }
    if (width != NULL) *width = cairo_image_surface_get_width(surface);
    if (height != NULL) *height = cairo_image_surface_get_height(surface);
    cairo_surface_destroy(surface);
    return 0;
}

int ss_pdf_draw_png(SsPdf *pdf, const char *path, double x, double y, double width, double height) {
    if (pdf == NULL || pdf->cr == NULL) return 1;
    cairo_surface_t *image = cairo_image_surface_create_from_png(path);
    if (image == NULL || cairo_surface_status(image) != CAIRO_STATUS_SUCCESS) {
        if (image != NULL) cairo_surface_destroy(image);
        return 1;
    }

    double source_width = cairo_image_surface_get_width(image);
    double source_height = cairo_image_surface_get_height(image);
    if (source_width <= 0 || source_height <= 0) {
        cairo_surface_destroy(image);
        return 1;
    }

    cairo_save(pdf->cr);
    cairo_translate(pdf->cr, x, y);
    cairo_scale(pdf->cr, width / source_width, height / source_height);
    cairo_set_source_surface(pdf->cr, image, 0, 0);
    cairo_paint(pdf->cr);
    cairo_restore(pdf->cr);
    cairo_surface_destroy(image);
    return cairo_status(pdf->cr) == CAIRO_STATUS_SUCCESS ? 0 : 1;
}

int ss_svg_size(const char *path, double *width, double *height) {
    GError *error = NULL;
    RsvgHandle *handle = rsvg_handle_new_from_file(path, &error);
    if (handle == NULL) {
        if (error != NULL) g_error_free(error);
        return 1;
    }

    RsvgDimensionData dimensions;
    rsvg_handle_get_dimensions(handle, &dimensions);
    if (width != NULL) *width = dimensions.width;
    if (height != NULL) *height = dimensions.height;
    g_object_unref(handle);
    return dimensions.width > 0 && dimensions.height > 0 ? 0 : 1;
}

int ss_pdf_draw_svg(SsPdf *pdf, const char *path, double x, double y, double width, double height) {
    if (pdf == NULL || pdf->cr == NULL) return 1;

    GError *error = NULL;
    RsvgHandle *handle = rsvg_handle_new_from_file(path, &error);
    if (handle == NULL) {
        if (error != NULL) g_error_free(error);
        return 1;
    }

    RsvgDimensionData dimensions;
    rsvg_handle_get_dimensions(handle, &dimensions);
    if (dimensions.width <= 0 || dimensions.height <= 0) {
        g_object_unref(handle);
        return 1;
    }

    cairo_save(pdf->cr);
    cairo_translate(pdf->cr, x, y);
    cairo_scale(pdf->cr, width / dimensions.width, height / dimensions.height);
    gboolean ok = rsvg_handle_render_cairo(handle, pdf->cr);
    cairo_restore(pdf->cr);
    g_object_unref(handle);
    if (!ok) return 1;
    return cairo_status(pdf->cr) == CAIRO_STATUS_SUCCESS ? 0 : 1;
}

int ss_pdf_draw_svg_tinted(SsPdf *pdf, const char *path, double x, double y, double width, double height, double r, double g, double b) {
    if (pdf == NULL || pdf->cr == NULL) return 1;

    GError *error = NULL;
    RsvgHandle *handle = rsvg_handle_new_from_file(path, &error);
    if (handle == NULL) {
        if (error != NULL) g_error_free(error);
        return 1;
    }

    RsvgDimensionData dimensions;
    rsvg_handle_get_dimensions(handle, &dimensions);
    if (dimensions.width <= 0 || dimensions.height <= 0) {
        g_object_unref(handle);
        return 1;
    }

    cairo_save(pdf->cr);
    cairo_translate(pdf->cr, x, y);
    cairo_scale(pdf->cr, width / dimensions.width, height / dimensions.height);
    cairo_push_group(pdf->cr);
    gboolean ok = rsvg_handle_render_cairo(handle, pdf->cr);
    cairo_pattern_t *mask = cairo_pop_group(pdf->cr);
    if (ok) {
        cairo_set_source_rgb(pdf->cr, r, g, b);
        cairo_mask(pdf->cr, mask);
    }
    cairo_pattern_destroy(mask);
    cairo_restore(pdf->cr);
    g_object_unref(handle);
    if (!ok) return 1;
    return cairo_status(pdf->cr) == CAIRO_STATUS_SUCCESS ? 0 : 1;
}
