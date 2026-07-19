#ifndef SS_RENDER_PDF_INTERNAL_H
#define SS_RENDER_PDF_INTERNAL_H

#include "backend.h"

#include <cairo.h>

cairo_t *ss_pdf_cairo_context(SsPdf *pdf);
void ss_pdf_set_error(SsPdf *pdf, const char *message);

#endif
