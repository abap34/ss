#ifndef SS_RENDER_PDF_BACKEND_H
#define SS_RENDER_PDF_BACKEND_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct SsPdf SsPdf;
typedef struct SsPdfInkExtents {
    double x;
    double y;
    double width;
    double height;
} SsPdfInkExtents;

typedef struct SsRasterMetadata {
    size_t pixel_width;
    size_t pixel_height;
    size_t oriented_width;
    size_t oriented_height;
    int orientation;
    int has_alpha;
    int color_space;
} SsRasterMetadata;

typedef struct SsSvgMetadata {
    double width;
    double height;
    int has_view_box;
    double view_box_x;
    double view_box_y;
    double view_box_width;
    double view_box_height;
} SsSvgMetadata;

typedef struct SsPdfDocumentMetadata {
    size_t page_count;
    int encrypted;
    int has_javascript;
} SsPdfDocumentMetadata;

typedef struct SsPdfPageMetadata {
    double boxes[5][4];
    double user_unit;
    int rotation;
    size_t annotation_count;
    int has_unsafe_annotations;
} SsPdfPageMetadata;

typedef struct SsTextGlyph {
    unsigned int id;
    double offset_x;
    double offset_y;
    double advance_x;
    double advance_y;
} SsTextGlyph;

typedef struct SsMathConstants {
    int has_data;
    double script_scale;
    double script_script_scale;
    double axis_height;
    double subscript_shift_down;
    double subscript_top_max;
    double subscript_baseline_drop_min;
    double superscript_shift_up;
    double superscript_bottom_min;
    double superscript_baseline_drop_max;
    double sub_superscript_gap_min;
    double superscript_bottom_max_with_subscript;
    double space_after_script;
    double fraction_numerator_shift_up;
    double fraction_numerator_display_shift_up;
    double fraction_denominator_shift_down;
    double fraction_denominator_display_shift_down;
    double fraction_numerator_gap_min;
    double fraction_numerator_display_gap_min;
    double fraction_rule_thickness;
    double fraction_denominator_gap_min;
    double fraction_denominator_display_gap_min;
    double radical_vertical_gap;
    double radical_display_vertical_gap;
    double radical_rule_thickness;
    double radical_extra_ascender;
} SsMathConstants;

typedef struct SsTextRun {
    size_t source_start;
    size_t source_end;
    size_t glyph_start;
    size_t glyph_count;
    size_t cluster_start;
    size_t cluster_count;
    double x;
    double baseline_y;
    double advance;
    double ascent;
    double descent;
    double line_gap;
    double underline_position;
    double underline_thickness;
    double strikethrough_position;
    double strikethrough_thickness;
    SsMathConstants math;
    char *font_family;
    char *font_path;
    unsigned int font_index;
    char *font_postscript_name;
    int font_weight;
    int font_style;
    int font_stretch;
    int synthetic_bold;
    int synthetic_italic;
    char *language;
    unsigned char bidi_level;
} SsTextRun;

typedef struct SsTextCluster {
    size_t source_start;
    size_t source_end;
    size_t glyph_start;
    size_t glyph_count;
    double x;
    double baseline_y;
    double advance_x;
    double advance_y;
    SsPdfInkExtents logical_bounds;
    SsPdfInkExtents ink_bounds;
} SsTextCluster;

typedef struct SsTextLine {
    size_t source_start;
    size_t source_end;
    size_t run_start;
    size_t run_count;
    double baseline_y;
    SsPdfInkExtents logical_bounds;
    SsPdfInkExtents ink_bounds;
} SsTextLine;

typedef struct SsTextShape {
    SsTextLine *lines;
    size_t line_count;
    SsTextRun *runs;
    size_t run_count;
    SsTextCluster *clusters;
    size_t cluster_count;
    SsTextGlyph *glyphs;
    size_t glyph_count;
    SsPdfInkExtents logical_bounds;
    SsPdfInkExtents ink_bounds;
} SsTextShape;

typedef struct SsTextMeasurement {
    SsPdfInkExtents logical_bounds;
    SsPdfInkExtents ink_bounds;
    double first_baseline;
} SsTextMeasurement;

typedef struct SsReplayGlyph {
    unsigned long id;
    double x;
    double y;
} SsReplayGlyph;

typedef struct SsReplayCluster {
    int bytes;
    int glyphs;
} SsReplayCluster;

typedef struct SsLayerEffects {
    double xx;
    double yx;
    double xy;
    double yy;
    double x0;
    double y0;
    int has_clip;
    double clip_x;
    double clip_y;
    double clip_width;
    double clip_height;
    double opacity;
    int blend_mode;
} SsLayerEffects;

typedef struct SsQpdfLayer {
    const char *path;
    size_t page_index;
    int box;
    double x;
    double y;
    double width;
    double height;
    int copy_annotations;
    SsLayerEffects effects;
} SsQpdfLayer;

const char *ss_pdf_cairo_version_string(void);
const char *ss_pdf_pango_version_string(void);
const char *ss_pdf_librsvg_version_string(void);
const char *ss_pdf_gdk_pixbuf_version_string(void);
int ss_pdf_fontconfig_version(void);
const char *ss_pdf_harfbuzz_version_string(void);
int ss_font_register(const char *path);

SsPdf *ss_pdf_create(const char *path, double width, double height);
void ss_pdf_destroy(SsPdf *pdf);
const char *ss_pdf_status_string(const SsPdf *pdf);
void ss_pdf_set_creator(SsPdf *pdf, const char *creator);
void ss_pdf_begin_page(SsPdf *pdf, double width, double height);
void ss_pdf_end_page(SsPdf *pdf);
int ss_pdf_finish(SsPdf *pdf);
int ss_pdf_begin_item(SsPdf *pdf, const SsLayerEffects *effects);
int ss_pdf_end_item(SsPdf *pdf);
void ss_pdf_fill_rect(SsPdf *pdf, double x, double y, double width, double height, double r, double g, double b);
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
);
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
);
void ss_pdf_state_save(SsPdf *pdf);
void ss_pdf_state_restore(SsPdf *pdf);
void ss_pdf_path_new(SsPdf *pdf);
void ss_pdf_path_move_to(SsPdf *pdf, double x, double y);
void ss_pdf_path_line_to(SsPdf *pdf, double x, double y);
void ss_pdf_path_curve_to(SsPdf *pdf, double x1, double y1, double x2, double y2, double x3, double y3);
void ss_pdf_path_close(SsPdf *pdf);
void ss_pdf_path_clip(SsPdf *pdf, int fill_rule);
void ss_pdf_path_fill_solid(SsPdf *pdf, double r, double g, double b, double alpha, int fill_rule);
void ss_pdf_path_fill_linear(
    SsPdf *pdf,
    double x1,
    double y1,
    double x2,
    double y2,
    const double *offsets,
    const double *colors,
    size_t stop_count,
    int spread,
    double alpha,
    int fill_rule
);
void ss_pdf_path_fill_radial(
    SsPdf *pdf,
    double x1,
    double y1,
    double radius1,
    double x2,
    double y2,
    double radius2,
    const double *offsets,
    const double *colors,
    size_t stop_count,
    int spread,
    double alpha,
    int fill_rule
);
void ss_pdf_path_stroke(
    SsPdf *pdf,
    double r,
    double g,
    double b,
    double alpha,
    double line_width,
    int line_cap,
    int line_join,
    double miter_limit,
    const double *dashes,
    size_t dash_count,
    double dash_offset
);
int ss_pdf_begin_uri_link(SsPdf *pdf, double x, double y, double width, double height, const char *uri);
int ss_pdf_begin_dest_link(SsPdf *pdf, double x, double y, double width, double height, const char *dest);
void ss_pdf_end_link(SsPdf *pdf);
int ss_pdf_add_destination(SsPdf *pdf, const char *name, double x, double y);
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
);
double ss_text_measure_text(const char *text, const char *font_family, int font_weight, int font_style, int font_stretch, double font_size);
double ss_text_measure_text_visual_width(const char *text, const char *font_family, int font_weight, int font_style, int font_stretch, double font_size);
int ss_text_measure_layout(
    const char *text,
    const char *font_family,
    int font_weight,
    int font_style,
    int font_stretch,
    double font_size,
    double width,
    int wrap,
    SsTextMeasurement *measurement
);
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
);
void ss_text_shape_free(SsTextShape *shape);
int ss_raster_size(const char *path, double *width, double *height);
int ss_raster_metadata_bytes(const unsigned char *bytes, size_t length, SsRasterMetadata *metadata);
int ss_pdf_draw_raster(SsPdf *pdf, const char *path, double x, double y, double width, double height);
int ss_svg_size(const char *path, double *width, double *height);
int ss_svg_metadata_bytes(const unsigned char *bytes, size_t length, SsSvgMetadata *metadata);
int ss_pdf_draw_svg(SsPdf *pdf, const char *path, double x, double y, double width, double height);
int ss_pdf_draw_svg_tinted(SsPdf *pdf, const char *path, double x, double y, double width, double height, double r, double g, double b);
#if defined(__GNUC__) || defined(__clang__)
#define SS_QPDF_BRIDGE_API __attribute__((visibility("default")))
#else
#define SS_QPDF_BRIDGE_API
#endif

SS_QPDF_BRIDGE_API const char *ss_qpdf_version_string(void);
SS_QPDF_BRIDGE_API int ss_qpdf_merge(const char *output, const char *const *inputs, size_t input_count, int single_page_inputs);
SS_QPDF_BRIDGE_API int ss_qpdf_empty(const char *output);
SS_QPDF_BRIDGE_API int ss_qpdf_page_size(const char *path, size_t page_index, int box, double *width, double *height);
SS_QPDF_BRIDGE_API int ss_qpdf_page_sizes(const char *path, int box, double *widths, double *heights, size_t page_count);
SS_QPDF_BRIDGE_API int ss_qpdf_metadata_bytes(
    const unsigned char *bytes,
    size_t length,
    SsPdfDocumentMetadata *document,
    SsPdfPageMetadata *pages,
    size_t page_capacity
);
SS_QPDF_BRIDGE_API int ss_qpdf_compose(const char *output, const SsQpdfLayer *layers, size_t layer_count);
SS_QPDF_BRIDGE_API const char *ss_qpdf_last_error(void);

#undef SS_QPDF_BRIDGE_API

#ifdef __cplusplus
}
#endif

#endif
