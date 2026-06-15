#ifndef SS_PDF_H
#define SS_PDF_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct SsPdf SsPdf;

SsPdf *ss_pdf_create(const char *path, double width, double height);
void ss_pdf_destroy(SsPdf *pdf);
void ss_pdf_set_creator(SsPdf *pdf, const char *creator);
void ss_pdf_begin_page(SsPdf *pdf, double width, double height);
void ss_pdf_end_page(SsPdf *pdf);
int ss_pdf_finish(SsPdf *pdf);

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
void ss_pdf_push_clip_rect(SsPdf *pdf, double x, double y, double width, double height);
void ss_pdf_pop_clip(SsPdf *pdf);
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
