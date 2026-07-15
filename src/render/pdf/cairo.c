#include "backend.h"

#include <cairo-pdf.h>
#include <cairo-ft.h>
#include <cairo.h>
#include <fontconfig/fontconfig.h>
#include <gdk-pixbuf/gdk-pixbuf.h>
#include <glib.h>
#include <hb.h>
#include <librsvg/rsvg.h>
#include <pango/pangocairo.h>
#include <pango/pangofc-font.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <ft2build.h>
#include FT_FREETYPE_H

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

static int ss_pdf_surface_ink_extents(cairo_surface_t *surface, SsPdfInkExtents *extents) {
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

typedef struct SsFtFaceData {
    FT_Library library;
    FT_Face face;
} SsFtFaceData;

static cairo_user_data_key_t ss_ft_face_data_key;

static void ss_ft_face_data_destroy(void *opaque) {
    SsFtFaceData *data = (SsFtFaceData *)opaque;
    if (data == NULL) return;
    if (data->face != NULL) FT_Done_Face(data->face);
    if (data->library != NULL) FT_Done_FreeType(data->library);
    free(data);
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

const char *ss_pdf_gdk_pixbuf_version_string(void) {
    return gdk_pixbuf_version;
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

SsPdf *ss_pdf_create_scratch(void) {
    SsPdf *pdf = (SsPdf *)calloc(1, sizeof(SsPdf));
    if (pdf == NULL) return NULL;

    pdf->surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, 1, 1);
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
    if (pdf == NULL || pdf->surface == NULL || pdf->pdf_cr == NULL || pdf->measurement != NULL) return 1;
    cairo_surface_finish(pdf->surface);
    if (cairo_status(pdf->pdf_cr) != CAIRO_STATUS_SUCCESS) return 1;
    if (cairo_surface_status(pdf->surface) != CAIRO_STATUS_SUCCESS) return 1;
    return 0;
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

int ss_pdf_measurement_ink_extents(SsPdf *pdf, SsPdfInkExtents *extents) {
    if (pdf == NULL || pdf->measurement == NULL || extents == NULL) return 1;
    return ss_pdf_surface_ink_extents(pdf->measurement->surface, extents);
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

int ss_pdf_draw_glyph_run(
    SsPdf *pdf,
    const char *font_path,
    long font_index,
    double font_size,
    double r,
    double g,
    double b,
    const char *utf8,
    int utf8_length,
    const SsReplayGlyph *glyphs,
    int glyph_count,
    const SsReplayCluster *clusters,
    int cluster_count,
    int backward
) {
    if (pdf == NULL || pdf->cr == NULL || font_path == NULL || utf8 == NULL || utf8_length < 0 ||
        glyph_count < 0 || cluster_count < 0 || font_size <= 0) return 1;

    FT_Library library = NULL;
    FT_Face face = NULL;
    cairo_font_face_t *cairo_face = NULL;
    cairo_glyph_t *cairo_glyphs = NULL;
    cairo_text_cluster_t *cairo_clusters = NULL;
    SsFtFaceData *face_data = NULL;
    int result = 1;

    if (FT_Init_FreeType(&library) != 0) goto cleanup;
    if (FT_New_Face(library, font_path, font_index, &face) != 0) goto cleanup;
    cairo_face = cairo_ft_font_face_create_for_ft_face(face, 0);
    if (cairo_face == NULL || cairo_font_face_status(cairo_face) != CAIRO_STATUS_SUCCESS) goto cleanup;
    face_data = (SsFtFaceData *)calloc(1, sizeof(SsFtFaceData));
    if (face_data == NULL) goto cleanup;
    face_data->library = library;
    face_data->face = face;
    if (cairo_font_face_set_user_data(cairo_face, &ss_ft_face_data_key, face_data, ss_ft_face_data_destroy) != CAIRO_STATUS_SUCCESS) {
        goto cleanup;
    }
    face_data = NULL;
    library = NULL;
    face = NULL;

    if (glyph_count > 0) {
        cairo_glyphs = cairo_glyph_allocate(glyph_count);
        if (cairo_glyphs == NULL) goto cleanup;
        for (int index = 0; index < glyph_count; index++) {
            cairo_glyphs[index].index = glyphs[index].id;
            cairo_glyphs[index].x = glyphs[index].x;
            cairo_glyphs[index].y = glyphs[index].y;
        }
    }
    if (cluster_count > 0) {
        cairo_clusters = cairo_text_cluster_allocate(cluster_count);
        if (cairo_clusters == NULL) goto cleanup;
        for (int index = 0; index < cluster_count; index++) {
            cairo_clusters[index].num_bytes = clusters[index].bytes;
            cairo_clusters[index].num_glyphs = clusters[index].glyphs;
        }
    }

    cairo_save(pdf->cr);
    cairo_set_font_face(pdf->cr, cairo_face);
    cairo_set_font_size(pdf->cr, font_size);
    ss_pdf_set_rgb(r, g, b, pdf->cr);
    cairo_show_text_glyphs(
        pdf->cr,
        utf8,
        utf8_length,
        cairo_glyphs,
        glyph_count,
        cairo_clusters,
        cluster_count,
        backward ? CAIRO_TEXT_CLUSTER_FLAG_BACKWARD : 0
    );
    cairo_restore(pdf->cr);
    result = cairo_status(pdf->cr) == CAIRO_STATUS_SUCCESS ? 0 : 1;

cleanup:
    if (cairo_clusters != NULL) cairo_text_cluster_free(cairo_clusters);
    if (cairo_glyphs != NULL) cairo_glyph_free(cairo_glyphs);
    if (cairo_face != NULL) cairo_font_face_destroy(cairo_face);
    if (face_data != NULL) free(face_data);
    if (face != NULL) FT_Done_Face(face);
    if (library != NULL) FT_Done_FreeType(library);
    return result;
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

static GMutex ss_text_context_mutex;

static SsPdfInkExtents ss_pango_extents(PangoRectangle rect) {
    SsPdfInkExtents result;
    result.x = ((double)rect.x) / PANGO_SCALE;
    result.y = ((double)rect.y) / PANGO_SCALE;
    result.width = ((double)rect.width) / PANGO_SCALE;
    result.height = ((double)rect.height) / PANGO_SCALE;
    return result;
}

static char *ss_font_family_copy(PangoFont *font) {
    if (font == NULL) return g_strdup("");
    PangoFontDescription *description = pango_font_describe(font);
    if (description == NULL) return g_strdup("");
    const char *family = pango_font_description_get_family(description);
    char *result = g_strdup(family != NULL ? family : "");
    pango_font_description_free(description);
    return result;
}

static void ss_font_source_copy(
    PangoFont *font,
    char **path_out,
    unsigned int *index_out,
    char **postscript_name_out,
    int *synthetic_bold_out,
    int *synthetic_italic_out
) {
    *path_out = g_strdup("");
    *index_out = 0;
    *postscript_name_out = g_strdup("");
    *synthetic_bold_out = 0;
    *synthetic_italic_out = 0;
    if (font == NULL) return;
    FcPattern *owned_match = NULL;
    FcPattern *pattern = NULL;
    if (PANGO_IS_FC_FONT(font)) {
        pattern = pango_fc_font_get_pattern(PANGO_FC_FONT(font));
    }
    if (pattern == NULL) {
        PangoFontDescription *description = pango_font_describe(font);
        const char *family = description != NULL ? pango_font_description_get_family(description) : NULL;
        FcPattern *query = FcPatternCreate();
        if (query != NULL) {
            if (family != NULL) FcPatternAddString(query, FC_FAMILY, (const FcChar8 *)family);
            if (description != NULL) {
                FcPatternAddInteger(query, FC_WEIGHT, FcWeightFromOpenTypeDouble((double)pango_font_description_get_weight(description)));
                const PangoStyle style = pango_font_description_get_style(description);
                FcPatternAddInteger(query, FC_SLANT, style == PANGO_STYLE_NORMAL ? FC_SLANT_ROMAN : (style == PANGO_STYLE_ITALIC ? FC_SLANT_ITALIC : FC_SLANT_OBLIQUE));
            }
            FcConfigSubstitute(NULL, query, FcMatchPattern);
            FcDefaultSubstitute(query);
            FcResult result = FcResultNoMatch;
            owned_match = FcFontMatch(NULL, query, &result);
            FcPatternDestroy(query);
            pattern = owned_match;
        }
        if (description != NULL) pango_font_description_free(description);
    }
    if (pattern != NULL) {
        FcChar8 *path = NULL;
        int index = 0;
        FcChar8 *postscript_name = NULL;
        if (FcPatternGetString(pattern, FC_FILE, 0, &path) == FcResultMatch && path != NULL) {
            g_free(*path_out);
            *path_out = g_strdup((const char *)path);
        }
        if (FcPatternGetInteger(pattern, FC_INDEX, 0, &index) == FcResultMatch && index >= 0) {
            *index_out = (unsigned int)index;
        }
        if (FcPatternGetString(pattern, FC_POSTSCRIPT_NAME, 0, &postscript_name) == FcResultMatch && postscript_name != NULL) {
            g_free(*postscript_name_out);
            *postscript_name_out = g_strdup((const char *)postscript_name);
        }
        FcBool embolden = FcFalse;
        if (FcPatternGetBool(pattern, FC_EMBOLDEN, 0, &embolden) == FcResultMatch) {
            *synthetic_bold_out = embolden == FcTrue;
        }
        FcMatrix *matrix = NULL;
        if (FcPatternGetMatrix(pattern, FC_MATRIX, 0, &matrix) == FcResultMatch && matrix != NULL) {
            *synthetic_italic_out = matrix->xy != 0 || matrix->yx != 0;
        }
    }
    if (owned_match != NULL) FcPatternDestroy(owned_match);
}

void ss_text_shape_free(SsTextShape *shape) {
    if (shape == NULL) return;
    if (shape->runs != NULL) {
        for (size_t index = 0; index < shape->run_count; index++) {
            g_free(shape->runs[index].font_family);
            g_free(shape->runs[index].font_path);
            g_free(shape->runs[index].font_postscript_name);
            g_free(shape->runs[index].language);
        }
    }
    free(shape->lines);
    free(shape->runs);
    free(shape->clusters);
    free(shape->glyphs);
    memset(shape, 0, sizeof(*shape));
}

int ss_text_shape(
    const char *text,
    const char *font_family,
    int font_weight,
    int font_style,
    int font_stretch,
    double font_size,
    double width,
    int wrap,
    SsTextShape *shape
) {
    if (text == NULL || shape == NULL || font_size <= 0) return 1;
    memset(shape, 0, sizeof(*shape));
    g_mutex_lock(&ss_text_context_mutex);
    cairo_t *cr = ss_text_measure_context();
    if (cr == NULL) {
        g_mutex_unlock(&ss_text_context_mutex);
        return 1;
    }
    PangoLayout *layout = pango_cairo_create_layout(cr);
    if (layout == NULL) {
        g_mutex_unlock(&ss_text_context_mutex);
        return 1;
    }
    PangoFontDescription *description = ss_font_description(font_family, font_weight, font_style, font_stretch, font_size);
    if (description == NULL) {
        g_object_unref(layout);
        g_mutex_unlock(&ss_text_context_mutex);
        return 1;
    }
    pango_layout_set_font_description(layout, description);
    pango_font_description_free(description);
    char *valid_text = g_utf8_make_valid(text, -1);
    if (valid_text == NULL) {
        g_object_unref(layout);
        g_mutex_unlock(&ss_text_context_mutex);
        return 1;
    }
    pango_layout_set_text(layout, valid_text, -1);
    if (wrap && width > 0) {
        pango_layout_set_width(layout, (int)(width * PANGO_SCALE));
        pango_layout_set_wrap(layout, PANGO_WRAP_WORD_CHAR);
    } else {
        pango_layout_set_width(layout, -1);
    }

    const int line_count = pango_layout_get_line_count(layout);
    size_t run_count = 0;
    size_t cluster_count = 0;
    size_t glyph_count = 0;
    for (int line_index = 0; line_index < line_count; line_index++) {
        PangoLayoutLine *line = pango_layout_get_line_readonly(layout, line_index);
        if (line == NULL) continue;
        for (GSList *entry = line->runs; entry != NULL; entry = entry->next) {
            PangoGlyphItem *item = (PangoGlyphItem *)entry->data;
            if (item == NULL || item->glyphs == NULL) continue;
            run_count++;
            glyph_count += (size_t)item->glyphs->num_glyphs;
            for (int glyph_index = 0; glyph_index < item->glyphs->num_glyphs; glyph_index++) {
                if (glyph_index == 0 || item->glyphs->log_clusters[glyph_index] != item->glyphs->log_clusters[glyph_index - 1]) {
                    cluster_count++;
                }
            }
        }
    }
    shape->lines = (SsTextLine *)calloc((size_t)line_count, sizeof(SsTextLine));
    shape->runs = (SsTextRun *)calloc(run_count, sizeof(SsTextRun));
    shape->clusters = (SsTextCluster *)calloc(cluster_count, sizeof(SsTextCluster));
    shape->glyphs = (SsTextGlyph *)calloc(glyph_count, sizeof(SsTextGlyph));
    if ((line_count > 0 && shape->lines == NULL) || (run_count > 0 && shape->runs == NULL) ||
        (cluster_count > 0 && shape->clusters == NULL) || (glyph_count > 0 && shape->glyphs == NULL)) {
        g_free(valid_text);
        g_object_unref(layout);
        g_mutex_unlock(&ss_text_context_mutex);
        ss_text_shape_free(shape);
        return 1;
    }
    shape->line_count = (size_t)line_count;
    shape->run_count = run_count;
    shape->cluster_count = cluster_count;
    shape->glyph_count = glyph_count;
    PangoRectangle layout_ink = {0};
    PangoRectangle layout_logical = {0};
    pango_layout_get_extents(layout, &layout_ink, &layout_logical);
    shape->ink_bounds = ss_pango_extents(layout_ink);
    shape->logical_bounds = ss_pango_extents(layout_logical);

    size_t next_run = 0;
    size_t next_cluster = 0;
    size_t next_glyph = 0;
    PangoLayoutIter *iterator = pango_layout_get_iter(layout);
    if (iterator == NULL) {
        g_free(valid_text);
        g_object_unref(layout);
        g_mutex_unlock(&ss_text_context_mutex);
        ss_text_shape_free(shape);
        return 1;
    }
    for (int line_index = 0; line_index < line_count; line_index++) {
        PangoLayoutLine *line = pango_layout_iter_get_line_readonly(iterator);
        SsTextLine *output_line = &shape->lines[line_index];
        PangoRectangle line_ink = {0};
        PangoRectangle line_logical = {0};
        pango_layout_iter_get_line_extents(iterator, &line_ink, &line_logical);
        output_line->source_start = line != NULL ? (size_t)line->start_index : 0;
        output_line->source_end = line != NULL ? (size_t)(line->start_index + line->length) : 0;
        output_line->run_start = next_run;
        output_line->baseline_y = ((double)pango_layout_iter_get_baseline(iterator)) / PANGO_SCALE;
        output_line->logical_bounds = ss_pango_extents(line_logical);
        output_line->ink_bounds = ss_pango_extents(line_ink);
        if (line != NULL) {
            double visual_x = 0;
            for (GSList *entry = line->runs; entry != NULL; entry = entry->next) {
                PangoGlyphItem *glyph_item = (PangoGlyphItem *)entry->data;
                if (glyph_item == NULL || glyph_item->item == NULL || glyph_item->glyphs == NULL) continue;
                PangoItem *item = glyph_item->item;
                PangoGlyphString *glyphs = glyph_item->glyphs;
                SsTextRun *run = &shape->runs[next_run++];
                run->source_start = (size_t)item->offset;
                run->source_end = (size_t)(item->offset + item->length);
                run->glyph_start = next_glyph;
                run->glyph_count = (size_t)glyphs->num_glyphs;
                run->cluster_start = next_cluster;
                run->x = visual_x;
                run->baseline_y = output_line->baseline_y;
                run->font_family = ss_font_family_copy(item->analysis.font);
                ss_font_source_copy(
                    item->analysis.font,
                    &run->font_path,
                    &run->font_index,
                    &run->font_postscript_name,
                    &run->synthetic_bold,
                    &run->synthetic_italic
                );
                PangoFontDescription *actual_font = item->analysis.font != NULL ? pango_font_describe(item->analysis.font) : NULL;
                run->font_weight = actual_font != NULL ? pango_font_description_get_weight(actual_font) : font_weight;
                run->font_style = actual_font != NULL ? pango_font_description_get_style(actual_font) : font_style;
                run->font_stretch = actual_font != NULL ? pango_font_description_get_stretch(actual_font) : font_stretch;
                if (actual_font != NULL) pango_font_description_free(actual_font);
                const char *language = item->analysis.language != NULL ? pango_language_to_string(item->analysis.language) : "";
                run->language = g_strdup(language != NULL ? language : "");
                run->bidi_level = item->analysis.level;
                PangoFontMetrics *metrics = item->analysis.font != NULL
                    ? pango_font_get_metrics(item->analysis.font, item->analysis.language)
                    : NULL;
                if (metrics != NULL) {
                    run->ascent = ((double)pango_font_metrics_get_ascent(metrics)) / PANGO_SCALE;
                    run->descent = ((double)pango_font_metrics_get_descent(metrics)) / PANGO_SCALE;
                    const double height = ((double)pango_font_metrics_get_height(metrics)) / PANGO_SCALE;
                    run->line_gap = fmax(height - run->ascent - run->descent, 0);
                    pango_font_metrics_unref(metrics);
                }
                double advance = 0;
                for (int glyph_index = 0; glyph_index < glyphs->num_glyphs; glyph_index++) {
                    PangoGlyphInfo info = glyphs->glyphs[glyph_index];
                    SsTextGlyph *glyph = &shape->glyphs[next_glyph++];
                    glyph->id = info.glyph;
                    glyph->offset_x = ((double)info.geometry.x_offset) / PANGO_SCALE;
                    glyph->offset_y = ((double)info.geometry.y_offset) / PANGO_SCALE;
                    glyph->advance_x = ((double)info.geometry.width) / PANGO_SCALE;
                    glyph->advance_y = 0;
                    advance += glyph->advance_x;
                }
                run->advance = advance;
                double cluster_x = 0;
                int cluster_glyph_start = 0;
                while (cluster_glyph_start < glyphs->num_glyphs) {
                    const int source_start = glyphs->log_clusters[cluster_glyph_start];
                    int cluster_glyph_end = cluster_glyph_start + 1;
                    while (cluster_glyph_end < glyphs->num_glyphs && glyphs->log_clusters[cluster_glyph_end] == source_start) {
                        cluster_glyph_end++;
                    }
                    double cluster_advance = 0;
                    for (int cluster_glyph = cluster_glyph_start; cluster_glyph < cluster_glyph_end; cluster_glyph++) {
                        cluster_advance += ((double)glyphs->glyphs[cluster_glyph].geometry.width) / PANGO_SCALE;
                    }
                    PangoRectangle cluster_ink = {0};
                    PangoRectangle cluster_logical = {0};
                    pango_glyph_string_extents_range(
                        glyphs,
                        cluster_glyph_start,
                        cluster_glyph_end,
                        item->analysis.font,
                        &cluster_ink,
                        &cluster_logical
                    );
                    SsTextCluster *cluster = &shape->clusters[next_cluster++];
                    cluster->source_start = (size_t)(item->offset + source_start);
                    cluster->source_end = run->source_end;
                    cluster->glyph_start = run->glyph_start + (size_t)cluster_glyph_start;
                    cluster->glyph_count = (size_t)(cluster_glyph_end - cluster_glyph_start);
                    cluster->x = cluster_x;
                    cluster->baseline_y = run->baseline_y;
                    cluster->advance_x = cluster_advance;
                    cluster->advance_y = 0;
                    cluster->logical_bounds = ss_pango_extents(cluster_logical);
                    cluster->logical_bounds.x += run->x + cluster_x;
                    cluster->logical_bounds.y += run->baseline_y;
                    cluster->ink_bounds = ss_pango_extents(cluster_ink);
                    cluster->ink_bounds.x += run->x + cluster_x;
                    cluster->ink_bounds.y += run->baseline_y;
                    cluster_x += cluster_advance;
                    cluster_glyph_start = cluster_glyph_end;
                }
                run->cluster_count = next_cluster - run->cluster_start;
                for (size_t cluster_index = run->cluster_start; cluster_index < next_cluster; cluster_index++) {
                    for (size_t candidate_index = run->cluster_start; candidate_index < next_cluster; candidate_index++) {
                        const size_t candidate_start = shape->clusters[candidate_index].source_start;
                        if (candidate_start > shape->clusters[cluster_index].source_start &&
                            candidate_start < shape->clusters[cluster_index].source_end) {
                            shape->clusters[cluster_index].source_end = candidate_start;
                        }
                    }
                }
                visual_x += advance;
            }
        }
        output_line->run_count = next_run - output_line->run_start;
        if (line_index + 1 < line_count) pango_layout_iter_next_line(iterator);
    }
    pango_layout_iter_free(iterator);
    g_free(valid_text);
    g_object_unref(layout);
    g_mutex_unlock(&ss_text_context_mutex);
    return 0;
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
    g_mutex_lock(&ss_text_context_mutex);
    const double width = ss_measure_text_on_cairo(ss_text_measure_context(), text, font_family, font_weight, font_style, font_stretch, font_size, 0);
    g_mutex_unlock(&ss_text_context_mutex);
    return width;
}

double ss_text_measure_text_visual_width(const char *text, const char *font_family, int font_weight, int font_style, int font_stretch, double font_size) {
    g_mutex_lock(&ss_text_context_mutex);
    const double width = ss_measure_text_on_cairo(ss_text_measure_context(), text, font_family, font_weight, font_style, font_stretch, font_size, 1);
    g_mutex_unlock(&ss_text_context_mutex);
    return width;
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

int ss_pdf_draw_raster(SsPdf *pdf, const char *path, double x, double y, double width, double height) {
    if (pdf == NULL || pdf->cr == NULL) return 1;
    GdkPixbuf *pixbuf = ss_raster_load_oriented(path);
    if (pixbuf == NULL) return 1;
    cairo_surface_t *image = ss_raster_surface_from_pixbuf(pixbuf);
    g_object_unref(pixbuf);
    if (image == NULL) return 1;

    const double source_width = cairo_image_surface_get_width(image);
    const double source_height = cairo_image_surface_get_height(image);
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
