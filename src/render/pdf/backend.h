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

typedef struct SsTextGlyph {
    unsigned int id;
    unsigned int source_index;
    double offset_x;
    double offset_y;
    double advance_x;
    double advance_y;
} SsTextGlyph;

typedef struct SsTextRun {
    size_t source_start;
    size_t source_end;
    size_t glyph_start;
    size_t glyph_count;
    double x;
    double baseline_y;
    double advance;
    char *font_family;
    char *font_path;
    unsigned int font_index;
    char *font_postscript_name;
} SsTextRun;

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
    SsTextGlyph *glyphs;
    size_t glyph_count;
    SsPdfInkExtents logical_bounds;
    SsPdfInkExtents ink_bounds;
} SsTextShape;

typedef struct SsReplayGlyph {
    unsigned long id;
    double x;
    double y;
} SsReplayGlyph;

typedef struct SsReplayCluster {
    int bytes;
    int glyphs;
} SsReplayCluster;

typedef struct SsQpdfLayer {
    const char *path;
    size_t page_index;
    int box;
    double x;
    double y;
    double width;
    double height;
    int copy_annotations;
} SsQpdfLayer;

const char *ss_pdf_cairo_version_string(void);
const char *ss_pdf_pango_version_string(void);
const char *ss_pdf_librsvg_version_string(void);
const char *ss_pdf_gdk_pixbuf_version_string(void);
int ss_pdf_fontconfig_version(void);
const char *ss_pdf_harfbuzz_version_string(void);
const char *ss_qpdf_version_string(void);

SsPdf *ss_pdf_create(const char *path, double width, double height);
SsPdf *ss_pdf_create_scratch(void);
void ss_pdf_destroy(SsPdf *pdf);
void ss_pdf_set_creator(SsPdf *pdf, const char *creator);
void ss_pdf_begin_page(SsPdf *pdf, double width, double height);
void ss_pdf_end_page(SsPdf *pdf);
int ss_pdf_finish(SsPdf *pdf);
int ss_pdf_begin_measurement(SsPdf *pdf);
int ss_pdf_measurement_ink_extents(SsPdf *pdf, SsPdfInkExtents *extents);
int ss_pdf_end_measurement(SsPdf *pdf);

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
int ss_pdf_begin_uri_link(SsPdf *pdf, double x, double y, double width, double height, const char *uri);
int ss_pdf_begin_dest_link(SsPdf *pdf, double x, double y, double width, double height, const char *dest);
void ss_pdf_end_link(SsPdf *pdf);
int ss_pdf_add_destination(SsPdf *pdf, const char *name, double x, double y);
int ss_pdf_draw_text_baseline(
    SsPdf *pdf,
    double x,
    double baseline_y,
    double width,
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
);
int ss_pdf_draw_color_text_baseline(
    SsPdf *pdf,
    double x,
    double baseline_y,
    double width,
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
);
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
double ss_pdf_measure_text(SsPdf *pdf, const char *text, const char *font_family, int font_weight, int font_style, int font_stretch, double font_size);
double ss_pdf_measure_text_visual_width(SsPdf *pdf, const char *text, const char *font_family, int font_weight, int font_style, int font_stretch, double font_size);
double ss_text_measure_text(const char *text, const char *font_family, int font_weight, int font_style, int font_stretch, double font_size);
double ss_text_measure_text_visual_width(const char *text, const char *font_family, int font_weight, int font_style, int font_stretch, double font_size);
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
int ss_pdf_draw_raster(SsPdf *pdf, const char *path, double x, double y, double width, double height);
int ss_svg_size(const char *path, double *width, double *height);
int ss_pdf_draw_svg(SsPdf *pdf, const char *path, double x, double y, double width, double height);
int ss_pdf_draw_svg_tinted(SsPdf *pdf, const char *path, double x, double y, double width, double height, double r, double g, double b);
int ss_qpdf_merge(const char *output, const char *const *inputs, size_t input_count, int single_page_inputs);
int ss_qpdf_empty(const char *output);
int ss_qpdf_page_size(const char *path, size_t page_index, int box, double *width, double *height);
int ss_qpdf_page_sizes(const char *path, int box, double *widths, double *heights, size_t page_count);
int ss_qpdf_compose(const char *output, const SsQpdfLayer *layers, size_t layer_count);
const char *ss_qpdf_last_error(void);

#ifdef __cplusplus
}
#endif

#endif
