#ifndef SS_PDF_H
#define SS_PDF_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct SsPdf SsPdf;
typedef struct SsPdfRecordingExtents {
    double x;
    double y;
    double width;
    double height;
} SsPdfRecordingExtents;

typedef struct SsPdfRecordingFit {
    SsPdfRecordingExtents bounds;
    double scale;
    double tx;
    double ty;
} SsPdfRecordingFit;

const char *ss_pdf_cairo_version_string(void);
const char *ss_pdf_pango_version_string(void);
const char *ss_pdf_librsvg_version_string(void);
int ss_pdf_fontconfig_version(void);
const char *ss_pdf_harfbuzz_version_string(void);

SsPdf *ss_pdf_create(const char *path, double width, double height);
void ss_pdf_destroy(SsPdf *pdf);
void ss_pdf_set_creator(SsPdf *pdf, const char *creator);
void ss_pdf_begin_page(SsPdf *pdf, double width, double height);
void ss_pdf_end_page(SsPdf *pdf);
int ss_pdf_finish(SsPdf *pdf);
int ss_pdf_begin_recording(SsPdf *pdf);
int ss_pdf_recording_ink_extents(SsPdf *pdf, SsPdfRecordingExtents *extents);
int ss_pdf_recording_fit(SsPdf *pdf, double page_width, double page_height, double margin, SsPdfRecordingFit *fit);
int ss_pdf_paint_recording_with_fit(SsPdf *pdf, const SsPdfRecordingFit *fit);
int ss_pdf_paint_recording_fit(SsPdf *pdf, double page_width, double page_height, double margin);
int ss_pdf_begin_measurement(SsPdf *pdf);
int ss_pdf_measurement_ink_extents(SsPdf *pdf, SsPdfRecordingExtents *extents);
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
);
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
);
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
);
double ss_pdf_measure_text(SsPdf *pdf, const char *text, const char *font_family, int font_weight, int font_style, int font_stretch, double font_size);
double ss_pdf_measure_text_visual_width(SsPdf *pdf, const char *text, const char *font_family, int font_weight, int font_style, int font_stretch, double font_size);
double ss_text_measure_text(const char *text, const char *font_family, int font_weight, int font_style, int font_stretch, double font_size);
double ss_text_measure_text_visual_width(const char *text, const char *font_family, int font_weight, int font_style, int font_stretch, double font_size);
int ss_png_size(const char *path, double *width, double *height);
int ss_pdf_draw_png(SsPdf *pdf, const char *path, double x, double y, double width, double height);
int ss_svg_size(const char *path, double *width, double *height);
int ss_pdf_draw_svg(SsPdf *pdf, const char *path, double x, double y, double width, double height);
int ss_pdf_draw_svg_tinted(SsPdf *pdf, const char *path, double x, double y, double width, double height, double r, double g, double b);

#ifdef __cplusplus
}
#endif

#endif
