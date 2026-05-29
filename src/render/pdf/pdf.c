#include "pdf.h"

#include <cairo-pdf.h>
#include <cairo.h>
#include <librsvg/rsvg.h>
#include <pango/pangocairo.h>
#include <stdlib.h>

#define SS_PI 3.14159265358979323846

struct SsPdf {
    cairo_surface_t *surface;
    cairo_t *cr;
};

static void ss_pdf_set_rgb(double r, double g, double b, cairo_t *cr) {
    cairo_set_source_rgb(cr, r, g, b);
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

SsPdf *ss_pdf_create(const char *path, double width, double height) {
    SsPdf *pdf = (SsPdf *)calloc(1, sizeof(SsPdf));
    if (pdf == NULL) return NULL;

    pdf->surface = cairo_pdf_surface_create(path, width, height);
    if (pdf->surface == NULL || cairo_surface_status(pdf->surface) != CAIRO_STATUS_SUCCESS) {
        ss_pdf_destroy(pdf);
        return NULL;
    }

    pdf->cr = cairo_create(pdf->surface);
    if (pdf->cr == NULL || cairo_status(pdf->cr) != CAIRO_STATUS_SUCCESS) {
        ss_pdf_destroy(pdf);
        return NULL;
    }

    return pdf;
}

void ss_pdf_destroy(SsPdf *pdf) {
    if (pdf == NULL) return;
    if (pdf->cr != NULL) cairo_destroy(pdf->cr);
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
    if (pdf == NULL || pdf->surface == NULL || pdf->cr == NULL) return 1;
    cairo_surface_finish(pdf->surface);
    if (cairo_status(pdf->cr) != CAIRO_STATUS_SUCCESS) return 1;
    if (cairo_surface_status(pdf->surface) != CAIRO_STATUS_SUCCESS) return 1;
    return 0;
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

int ss_pdf_draw_text(
    SsPdf *pdf,
    double x,
    double y,
    double width,
    double height,
    const char *text,
    const char *font_spec,
    double font_size,
    double r,
    double g,
    double b,
    int wrap
) {
    if (pdf == NULL || pdf->cr == NULL) return 1;

    PangoLayout *layout = pango_cairo_create_layout(pdf->cr);
    if (layout == NULL) return 1;

    PangoFontDescription *desc = pango_font_description_from_string(font_spec);
    if (desc == NULL) {
        g_object_unref(layout);
        return 1;
    }
    pango_font_description_set_absolute_size(desc, font_size * PANGO_SCALE);
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
    if (height > 0) pango_layout_set_height(layout, (int)(height * PANGO_SCALE));

    cairo_save(pdf->cr);
    cairo_rectangle(pdf->cr, x, y, width, height);
    cairo_clip(pdf->cr);
    ss_pdf_set_rgb(r, g, b, pdf->cr);
    cairo_move_to(pdf->cr, x, y);
    pango_cairo_show_layout(pdf->cr, layout);
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
    const char *font_spec,
    double font_size,
    double r,
    double g,
    double b,
    int wrap
) {
    if (pdf == NULL || pdf->cr == NULL) return 1;

    PangoLayout *layout = pango_cairo_create_layout(pdf->cr);
    if (layout == NULL) return 1;

    PangoFontDescription *desc = pango_font_description_from_string(font_spec);
    if (desc == NULL) {
        g_object_unref(layout);
        return 1;
    }
    pango_font_description_set_absolute_size(desc, font_size * PANGO_SCALE);
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
    if (height > 0) pango_layout_set_height(layout, (int)(height * PANGO_SCALE));

    double layout_y = baseline_y - ((double)pango_layout_get_baseline(layout)) / PANGO_SCALE;
    double clip_pad = font_size * 0.35;
    cairo_save(pdf->cr);
    cairo_rectangle(pdf->cr, x, clip_y - clip_pad, width, height + clip_pad * 2.0);
    cairo_clip(pdf->cr);
    ss_pdf_set_rgb(r, g, b, pdf->cr);
    cairo_move_to(pdf->cr, x, layout_y);
    pango_cairo_show_layout(pdf->cr, layout);
    cairo_restore(pdf->cr);

    g_object_unref(layout);
    return cairo_status(pdf->cr) == CAIRO_STATUS_SUCCESS ? 0 : 1;
}

double ss_pdf_measure_text(SsPdf *pdf, const char *text, const char *font_spec, double font_size) {
    if (pdf == NULL || pdf->cr == NULL) return 0.0;

    PangoLayout *layout = pango_cairo_create_layout(pdf->cr);
    if (layout == NULL) return 0.0;

    PangoFontDescription *desc = pango_font_description_from_string(font_spec);
    if (desc == NULL) {
        g_object_unref(layout);
        return 0.0;
    }
    pango_font_description_set_absolute_size(desc, font_size * PANGO_SCALE);
    pango_layout_set_font_description(layout, desc);
    pango_font_description_free(desc);
    char *valid_text = g_utf8_make_valid(text, -1);
    if (valid_text == NULL) {
        g_object_unref(layout);
        return 0.0;
    }
    pango_layout_set_text(layout, valid_text, -1);
    g_free(valid_text);

    int width = 0;
    int height = 0;
    pango_layout_get_size(layout, &width, &height);
    g_object_unref(layout);
    return ((double)width) / PANGO_SCALE;
}

double ss_pdf_measure_text_visual_width(SsPdf *pdf, const char *text, const char *font_spec, double font_size) {
    if (pdf == NULL || pdf->cr == NULL) return 0.0;

    PangoLayout *layout = pango_cairo_create_layout(pdf->cr);
    if (layout == NULL) return 0.0;

    PangoFontDescription *desc = pango_font_description_from_string(font_spec);
    if (desc == NULL) {
        g_object_unref(layout);
        return 0.0;
    }
    pango_font_description_set_absolute_size(desc, font_size * PANGO_SCALE);
    pango_layout_set_font_description(layout, desc);
    pango_font_description_free(desc);
    char *valid_text = g_utf8_make_valid(text, -1);
    if (valid_text == NULL) {
        g_object_unref(layout);
        return 0.0;
    }
    pango_layout_set_text(layout, valid_text, -1);
    g_free(valid_text);

    PangoRectangle ink = {0};
    PangoRectangle logical = {0};
    pango_layout_get_extents(layout, &ink, &logical);
    g_object_unref(layout);

    const double logical_width = ((double)logical.width) / PANGO_SCALE;
    const double ink_right = ((double)(ink.x + ink.width)) / PANGO_SCALE;
    return ink_right > logical_width ? ink_right : logical_width;
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
    cairo_rectangle(pdf->cr, x, y, width, height);
    cairo_clip(pdf->cr);
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
    cairo_rectangle(pdf->cr, x, y, width, height);
    cairo_clip(pdf->cr);
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
    cairo_rectangle(pdf->cr, x, y, width, height);
    cairo_clip(pdf->cr);
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
