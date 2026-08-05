#include "backend.h"

#include <cairo-pdf.h>
#include <cairo-ft.h>
#include <cairo.h>
#include <fontconfig/fontconfig.h>
#include <glib.h>
#include <glib/gstdio.h>
#include <hb.h>
#include <hb-ot.h>
#include <pango/pangocairo.h>
#include <pango/pangofc-font.h>
#include <pango/pangofc-fontmap.h>
#include <errno.h>
#include <locale.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#include <ft2build.h>
#include FT_FREETYPE_H

#define SS_PI 3.14159265358979323846
#define SS_FONT_SOURCE_CACHE_MAX_ENTRIES 1024

static GMutex ss_font_registration_mutex;
static GRWLock ss_font_config_lock;
static uint64_t ss_font_config_generation;
static unsigned char ss_font_environment_id[SS_FONT_ENVIRONMENT_ID_SIZE];
static uint64_t ss_font_environment_generation;
static int ss_font_environment_valid;
static FcConfig *ss_font_config;
static GMutex ss_font_source_cache_mutex;
static GHashTable *ss_font_source_cache;
static GPtrArray *ss_registered_font_paths;
static _Thread_local uint64_t ss_thread_font_config_generation;
static _Thread_local int ss_thread_font_config_valid;

static void ss_font_source_cache_clear(void);

static void ss_checksum_bytes(GChecksum *checksum, const void *bytes, size_t length) {
    unsigned char encoded_length[8];
    const uint64_t value = (uint64_t)length;
    for (size_t index = 0; index < sizeof(encoded_length); index++) {
        encoded_length[index] = (unsigned char)(value >> (index * 8));
    }
    g_checksum_update(checksum, encoded_length, sizeof(encoded_length));
    if (length != 0) g_checksum_update(checksum, (const guchar *)bytes, length);
}

static void ss_checksum_string(GChecksum *checksum, const char *value) {
    if (value == NULL) {
        ss_checksum_bytes(checksum, "", 0);
        return;
    }
    ss_checksum_bytes(checksum, value, strlen(value));
}

static void ss_checksum_environment_variable(GChecksum *checksum, const char *name) {
    ss_checksum_string(checksum, name);
    const char *value = g_getenv(name);
    const unsigned char present = value != NULL;
    ss_checksum_bytes(checksum, &present, sizeof(present));
    if (present) ss_checksum_string(checksum, value);
}

static void ss_checksum_stat(GChecksum *checksum, const GStatBuf *metadata) {
    ss_checksum_bytes(checksum, &metadata->st_mode, sizeof(metadata->st_mode));
    ss_checksum_bytes(checksum, &metadata->st_dev, sizeof(metadata->st_dev));
    ss_checksum_bytes(checksum, &metadata->st_ino, sizeof(metadata->st_ino));
    ss_checksum_bytes(checksum, &metadata->st_size, sizeof(metadata->st_size));
    ss_checksum_bytes(checksum, &metadata->st_mtime, sizeof(metadata->st_mtime));
    ss_checksum_bytes(checksum, &metadata->st_ctime, sizeof(metadata->st_ctime));
#if defined(__APPLE__)
    ss_checksum_bytes(checksum, &metadata->st_mtimespec.tv_nsec, sizeof(metadata->st_mtimespec.tv_nsec));
    ss_checksum_bytes(checksum, &metadata->st_ctimespec.tv_nsec, sizeof(metadata->st_ctimespec.tv_nsec));
#elif defined(__linux__)
    ss_checksum_bytes(checksum, &metadata->st_mtim.tv_nsec, sizeof(metadata->st_mtim.tv_nsec));
    ss_checksum_bytes(checksum, &metadata->st_ctim.tv_nsec, sizeof(metadata->st_ctim.tv_nsec));
#endif
}

static int ss_stat_matches(const GStatBuf *left, const GStatBuf *right) {
    if (
        left->st_mode != right->st_mode ||
        left->st_dev != right->st_dev ||
        left->st_ino != right->st_ino ||
        left->st_size != right->st_size ||
        left->st_mtime != right->st_mtime ||
        left->st_ctime != right->st_ctime
    ) {
        return 0;
    }
#if defined(__APPLE__)
    return left->st_mtimespec.tv_nsec == right->st_mtimespec.tv_nsec &&
        left->st_ctimespec.tv_nsec == right->st_ctimespec.tv_nsec;
#elif defined(__linux__)
    return left->st_mtim.tv_nsec == right->st_mtim.tv_nsec &&
        left->st_ctim.tv_nsec == right->st_ctim.tv_nsec;
#else
    return 1;
#endif
}

static gchar *ss_font_config_path(FcConfig *config, const char *path) {
    if (path == NULL) return NULL;
    const FcChar8 *sysroot = FcConfigGetSysRoot(config);
    if (sysroot == NULL || sysroot[0] == '\0') return g_strdup(path);
    if (g_path_is_absolute(path)) return g_strconcat((const char *)sysroot, path, NULL);
    return g_build_filename((const char *)sysroot, path, NULL);
}

static int ss_checksum_font_set(GChecksum *checksum, FcConfig *config, FcFontSet *font_set, const char *name) {
    ss_checksum_string(checksum, name);
    const int count = font_set != NULL ? font_set->nfont : 0;
    ss_checksum_bytes(checksum, &count, sizeof(count));
    for (int index = 0; index < count; index++) {
        FcPattern *pattern = font_set->fonts[index];
        FcChar8 *path = NULL;
        if (FcPatternGetString(pattern, FC_FILE, 0, &path) != FcResultMatch) path = NULL;
        ss_checksum_string(checksum, (const char *)path);
        int face_index = 0;
        if (FcPatternGetInteger(pattern, FC_INDEX, 0, &face_index) != FcResultMatch) face_index = 0;
        ss_checksum_bytes(checksum, &face_index, sizeof(face_index));
        if (path != NULL) {
            gchar *resolved_path = ss_font_config_path(config, (const char *)path);
            if (resolved_path == NULL) return 1;
            GStatBuf metadata;
            if (g_stat(resolved_path, &metadata) != 0) {
                g_free(resolved_path);
                return 1;
            }
            ss_checksum_stat(checksum, &metadata);
            g_free(resolved_path);
        }
    }
    return 0;
}

static int ss_checksum_path_list(GChecksum *checksum, FcConfig *config, FcStrList *paths, const char *name) {
    ss_checksum_string(checksum, name);
    if (paths == NULL) {
        const int count = 0;
        ss_checksum_bytes(checksum, &count, sizeof(count));
        return 0;
    }
    int count = 0;
    FcChar8 *path = NULL;
    while ((path = FcStrListNext(paths)) != NULL) {
        count++;
        ss_checksum_string(checksum, (const char *)path);
        gchar *resolved_path = ss_font_config_path(config, (const char *)path);
        if (resolved_path == NULL) {
            FcStrListDone(paths);
            return 1;
        }
        GStatBuf metadata;
        if (g_stat(resolved_path, &metadata) != 0) {
            const unsigned char present = 0;
            ss_checksum_bytes(checksum, &present, sizeof(present));
            const int missing = errno == ENOENT || errno == ENOTDIR;
            g_free(resolved_path);
            if (missing) continue;
            FcStrListDone(paths);
            return 1;
        }
        g_free(resolved_path);
        const unsigned char present = 1;
        ss_checksum_bytes(checksum, &present, sizeof(present));
        ss_checksum_stat(checksum, &metadata);
    }
    FcStrListDone(paths);
    ss_checksum_bytes(checksum, &count, sizeof(count));
    return 0;
}

/* The writer lock must be held because this function can replace or invalidate
 * the current thread's Pango font-map caches. */
static FcConfig *ss_sync_thread_pango_font_config_writer_locked(PangoFcFontMap **font_map_output) {
    PangoFontMap *font_map = pango_cairo_font_map_get_default();
    if (font_map == NULL || !PANGO_IS_FC_FONT_MAP(font_map)) return NULL;
    PangoFcFontMap *fc_font_map = PANGO_FC_FONT_MAP(font_map);
    if (font_map_output != NULL) *font_map_output = fc_font_map;
    if (ss_font_config == NULL) {
        ss_font_config = FcConfigReference(NULL);
        if (ss_font_config == NULL) return NULL;
    }
    FcConfig *attached = pango_fc_font_map_get_config(fc_font_map);
    if (attached != ss_font_config) {
        pango_fc_font_map_set_config(fc_font_map, ss_font_config);
        pango_fc_font_map_cache_clear(fc_font_map);
    } else if (!ss_thread_font_config_valid || ss_thread_font_config_generation != ss_font_config_generation) {
        pango_fc_font_map_config_changed(fc_font_map);
    }
    ss_thread_font_config_generation = ss_font_config_generation;
    ss_thread_font_config_valid = 1;
    return ss_font_config;
}

static int ss_compute_font_environment_for_config_locked(
    unsigned char output[SS_FONT_ENVIRONMENT_ID_SIZE],
    PangoFcFontMap *font_map,
    FcConfig *borrowed_config
) {
    GChecksum *checksum = g_checksum_new(G_CHECKSUM_SHA256);
    if (checksum == NULL) return 1;
    int failed = 0;

    ss_checksum_string(checksum, "ss-font-environment-v3");
    ss_checksum_string(checksum, cairo_version_string());
    ss_checksum_string(checksum, pango_version_string());
    ss_checksum_string(checksum, hb_version_string());
    const int fontconfig_version = FcGetVersion();
    ss_checksum_bytes(checksum, &fontconfig_version, sizeof(fontconfig_version));
    const int freetype_version[] = {FREETYPE_MAJOR, FREETYPE_MINOR, FREETYPE_PATCH};
    ss_checksum_bytes(checksum, freetype_version, sizeof(freetype_version));

    if (borrowed_config == NULL || font_map == NULL) {
        g_checksum_free(checksum);
        return 1;
    }
    FcConfig *config = FcConfigReference(borrowed_config);
    if (config == NULL) {
        g_checksum_free(checksum);
        return 1;
    }
    ss_checksum_string(checksum, G_OBJECT_TYPE_NAME(font_map));
    PangoLanguage *language = pango_language_get_default();
    ss_checksum_string(checksum, language != NULL ? pango_language_to_string(language) : NULL);
    ss_checksum_string(checksum, setlocale(LC_CTYPE, NULL));
    ss_checksum_string(checksum, g_get_prgname());

    const char *environment_names[] = {
        "FONTCONFIG_FILE",
        "FONTCONFIG_PATH",
        "FONTCONFIG_SYSROOT",
        "FC_LANG",
        "PANGO_LANGUAGE",
        "LC_ALL",
        "LC_CTYPE",
        "LANG",
        "LANGUAGE",
        "PANGOCAIRO_BACKEND",
        "FREETYPE_PROPERTIES",
        "HB_OPTIONS",
        "HB_SHAPER_LIST",
        "XDG_CURRENT_DESKTOP",
        "HOME",
        "XDG_CONFIG_HOME",
        "XDG_DATA_HOME",
        "XDG_DATA_DIRS",
        "XDG_CACHE_HOME",
    };
    for (size_t index = 0; index < sizeof(environment_names) / sizeof(environment_names[0]); index++) {
        ss_checksum_environment_variable(checksum, environment_names[index]);
    }

    ss_checksum_string(checksum, (const char *)FcConfigGetSysRoot(config));
    FcStrList *files = FcConfigGetConfigFiles(config);
    if (files != NULL) {
        FcChar8 *path = NULL;
        while ((path = FcStrListNext(files)) != NULL) {
            ss_checksum_string(checksum, (const char *)path);
            gchar *resolved_path = ss_font_config_path(config, (const char *)path);
            GStatBuf before;
            if (resolved_path == NULL || g_stat(resolved_path, &before) != 0) {
                g_free(resolved_path);
                failed = 1;
                break;
            }
            ss_checksum_stat(checksum, &before);
            if (S_ISREG(before.st_mode)) {
                gchar *contents = NULL;
                gsize length = 0;
                GStatBuf after;
                if (
                    !g_file_get_contents(resolved_path, &contents, &length, NULL) ||
                    g_stat(resolved_path, &after) != 0 ||
                    !ss_stat_matches(&before, &after)
                ) {
                    g_free(contents);
                    g_free(resolved_path);
                    failed = 1;
                    break;
                }
                ss_checksum_bytes(checksum, contents, length);
                g_free(contents);
            } else if (!S_ISDIR(before.st_mode)) {
                g_free(resolved_path);
                failed = 1;
                break;
            }
            g_free(resolved_path);
        }
        FcStrListDone(files);
    }
    if (!failed && ss_checksum_path_list(checksum, config, FcConfigGetFontDirs(config), "font-directories") != 0) failed = 1;
    if (!failed && ss_checksum_font_set(checksum, config, FcConfigGetFonts(config, FcSetSystem), "system-fonts") != 0) failed = 1;
    if (!failed && ss_checksum_font_set(checksum, config, FcConfigGetFonts(config, FcSetApplication), "application-fonts") != 0) failed = 1;
    if (!failed && FcConfigUptoDate(config) != FcTrue) failed = 1;
    if (failed) {
        FcConfigDestroy(config);
        g_checksum_free(checksum);
        return 1;
    }

    gsize digest_length = SS_FONT_ENVIRONMENT_ID_SIZE;
    g_checksum_get_digest(checksum, output, &digest_length);
    FcConfigDestroy(config);
    g_checksum_free(checksum);
    if (digest_length != SS_FONT_ENVIRONMENT_ID_SIZE) return 1;
    return 0;
}

static int ss_compute_font_environment_writer_locked(unsigned char output[SS_FONT_ENVIRONMENT_ID_SIZE]) {
    PangoFcFontMap *font_map = NULL;
    FcConfig *config = ss_sync_thread_pango_font_config_writer_locked(&font_map);
    return ss_compute_font_environment_for_config_locked(output, font_map, config);
}

static int ss_reload_font_config_writer_locked(
    PangoFcFontMap *font_map,
    unsigned char environment_id[SS_FONT_ENVIRONMENT_ID_SIZE]
) {
    if (font_map == NULL) return 1;
    FcConfig *config = FcInitLoadConfigAndFonts();
    if (config == NULL) return 1;
    int failed = 0;
    if (ss_registered_font_paths != NULL) {
        for (guint index = 0; index < ss_registered_font_paths->len; index++) {
            const char *path = g_ptr_array_index(ss_registered_font_paths, index);
            if (FcConfigAppFontAddFile(config, (const FcChar8 *)path) != FcTrue) {
                failed = 1;
                break;
            }
        }
    }
    if (!failed && ss_compute_font_environment_for_config_locked(environment_id, font_map, config) != 0) failed = 1;
    if (!failed && FcConfigSetCurrent(config) != FcTrue) failed = 1;
    if (failed) {
        FcConfigDestroy(config);
        return 1;
    }
    FcConfig *retained_config = FcConfigReference(config);
    pango_fc_font_map_set_config(font_map, config);
    pango_fc_font_map_cache_clear(font_map);
    if (ss_font_config != NULL) FcConfigDestroy(ss_font_config);
    ss_font_config = retained_config;
    FcConfigDestroy(config);
    ss_font_config_generation++;
    ss_thread_font_config_generation = ss_font_config_generation;
    ss_thread_font_config_valid = 1;
    memcpy(ss_font_environment_id, environment_id, sizeof(ss_font_environment_id));
    ss_font_environment_generation = ss_font_config_generation;
    ss_font_environment_valid = 1;
    ss_font_source_cache_clear();
    return 0;
}

typedef struct SsFontSource {
    char *path;
    unsigned int index;
    char *postscript_name;
    int synthetic_bold;
    int synthetic_italic;
} SsFontSource;

static void ss_font_source_destroy(void *opaque) {
    SsFontSource *source = (SsFontSource *)opaque;
    if (source == NULL) return;
    g_free(source->path);
    g_free(source->postscript_name);
    g_free(source);
}

static void ss_font_source_cache_clear(void) {
    g_mutex_lock(&ss_font_source_cache_mutex);
    if (ss_font_source_cache != NULL) g_hash_table_remove_all(ss_font_source_cache);
    g_mutex_unlock(&ss_font_source_cache_mutex);
}

typedef struct SsPdfFontFace {
    char *path;
    long index;
    cairo_font_face_t *face;
    struct SsPdfFontFace *next;
} SsPdfFontFace;

struct SsPdf {
    cairo_surface_t *surface;
    cairo_t *pdf_cr;
    cairo_t *cr;
    SsPdfFontFace *font_faces;
    double item_opacity;
    int item_blend_mode;
    int item_active;
    char error_message[512];
};

void ss_pdf_set_error(SsPdf *pdf, const char *message) {
    if (pdf == NULL || message == NULL) return;
    snprintf(pdf->error_message, sizeof(pdf->error_message), "%s", message);
}

cairo_t *ss_pdf_cairo_context(SsPdf *pdf) {
    return pdf == NULL ? NULL : pdf->cr;
}

static void ss_pdf_set_rgb(double r, double g, double b, cairo_t *cr) {
    cairo_set_source_rgb(cr, r, g, b);
}

static cairo_operator_t ss_pdf_blend_operator(int blend_mode) {
    switch (blend_mode) {
        case 1: return CAIRO_OPERATOR_MULTIPLY;
        case 2: return CAIRO_OPERATOR_SCREEN;
        case 3: return CAIRO_OPERATOR_OVERLAY;
        case 4: return CAIRO_OPERATOR_DARKEN;
        case 5: return CAIRO_OPERATOR_LIGHTEN;
        default: return CAIRO_OPERATOR_OVER;
    }
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

static void ss_pdf_destroy_font_faces(SsPdf *pdf) {
    if (pdf == NULL) return;
    while (pdf->font_faces != NULL) {
        SsPdfFontFace *entry = pdf->font_faces;
        pdf->font_faces = entry->next;
        if (entry->face != NULL) cairo_font_face_destroy(entry->face);
        free(entry->path);
        free(entry);
    }
}

static cairo_font_face_t *ss_pdf_font_face(SsPdf *pdf, const char *path, long index) {
    if (pdf == NULL || path == NULL) return NULL;
    for (SsPdfFontFace *entry = pdf->font_faces; entry != NULL; entry = entry->next) {
        if (entry->index == index && strcmp(entry->path, path) == 0) return entry->face;
    }

    FT_Library library = NULL;
    FT_Face face = NULL;
    cairo_font_face_t *cairo_face = NULL;
    SsFtFaceData *face_data = NULL;
    SsPdfFontFace *entry = NULL;
    if (FT_Init_FreeType(&library) != 0) goto fail;
    if (FT_New_Face(library, path, index, &face) != 0) goto fail;
    cairo_face = cairo_ft_font_face_create_for_ft_face(face, 0);
    if (cairo_face == NULL || cairo_font_face_status(cairo_face) != CAIRO_STATUS_SUCCESS) goto fail;
    face_data = (SsFtFaceData *)calloc(1, sizeof(SsFtFaceData));
    if (face_data == NULL) goto fail;
    face_data->library = library;
    face_data->face = face;
    if (cairo_font_face_set_user_data(cairo_face, &ss_ft_face_data_key, face_data, ss_ft_face_data_destroy) != CAIRO_STATUS_SUCCESS) {
        goto fail;
    }
    face_data = NULL;
    library = NULL;
    face = NULL;

    entry = (SsPdfFontFace *)calloc(1, sizeof(SsPdfFontFace));
    if (entry == NULL) goto fail;
    const size_t path_length = strlen(path);
    entry->path = (char *)malloc(path_length + 1);
    if (entry->path == NULL) goto fail;
    memcpy(entry->path, path, path_length + 1);
    entry->index = index;
    entry->face = cairo_face;
    entry->next = pdf->font_faces;
    pdf->font_faces = entry;
    return cairo_face;

fail:
    if (entry != NULL) {
        free(entry->path);
        free(entry);
    }
    if (cairo_face != NULL) cairo_font_face_destroy(cairo_face);
    if (face_data != NULL) free(face_data);
    if (face != NULL) FT_Done_Face(face);
    if (library != NULL) FT_Done_FreeType(library);
    return NULL;
}

const char *ss_pdf_cairo_version_string(void) {
    return cairo_version_string();
}

const char *ss_pdf_pango_version_string(void) {
    return pango_version_string();
}

int ss_pdf_fontconfig_version(void) {
    return FcGetVersion();
}

const char *ss_pdf_harfbuzz_version_string(void) {
    return hb_version_string();
}

int ss_font_register(const char *path) {
    if (path == NULL || path[0] == '\0') return 1;
    gchar *canonical_path = g_canonicalize_filename(path, NULL);
    if (canonical_path == NULL) return 1;
    g_mutex_lock(&ss_font_registration_mutex);
    g_rw_lock_writer_lock(&ss_font_config_lock);
    int known = 0;
    if (ss_registered_font_paths != NULL) {
        for (guint index = 0; index < ss_registered_font_paths->len; index++) {
            if (strcmp(canonical_path, g_ptr_array_index(ss_registered_font_paths, index)) == 0) {
                known = 1;
                break;
            }
        }
    }
    if (known) {
        g_rw_lock_writer_unlock(&ss_font_config_lock);
        g_mutex_unlock(&ss_font_registration_mutex);
        g_free(canonical_path);
        return 0;
    }
    PangoFcFontMap *font_map = NULL;
    FcConfig *config = ss_sync_thread_pango_font_config_writer_locked(&font_map);
    const FcBool added = config != NULL && font_map != NULL
        ? FcConfigAppFontAddFile(config, (const FcChar8 *)canonical_path)
        : FcFalse;
    if (added == FcTrue) {
        if (ss_registered_font_paths == NULL) {
            ss_registered_font_paths = g_ptr_array_new_with_free_func(g_free);
        }
        g_ptr_array_add(ss_registered_font_paths, canonical_path);
        canonical_path = NULL;
        pango_fc_font_map_config_changed(font_map);
        ss_font_config_generation++;
        ss_thread_font_config_generation = ss_font_config_generation;
        ss_thread_font_config_valid = 1;
        ss_font_environment_valid = 0;
        ss_font_source_cache_clear();
    }
    g_rw_lock_writer_unlock(&ss_font_config_lock);
    g_mutex_unlock(&ss_font_registration_mutex);
    g_free(canonical_path);
    return added == FcTrue ? 0 : 1;
}

uint64_t ss_font_generation(void) {
    g_rw_lock_reader_lock(&ss_font_config_lock);
    const uint64_t generation = ss_font_config_generation;
    g_rw_lock_reader_unlock(&ss_font_config_lock);
    return generation;
}

int ss_font_environment_snapshot(SsFontEnvironment *output) {
    if (output == NULL) return 1;
    g_rw_lock_reader_lock(&ss_font_config_lock);
    if (ss_font_environment_valid && ss_font_environment_generation == ss_font_config_generation) {
        memcpy(output->id, ss_font_environment_id, sizeof(output->id));
        output->generation = ss_font_config_generation;
        g_rw_lock_reader_unlock(&ss_font_config_lock);
        return 0;
    }
    g_rw_lock_reader_unlock(&ss_font_config_lock);

    g_rw_lock_writer_lock(&ss_font_config_lock);
    if (!ss_font_environment_valid || ss_font_environment_generation != ss_font_config_generation) {
        unsigned char candidate[SS_FONT_ENVIRONMENT_ID_SIZE];
        if (ss_compute_font_environment_writer_locked(candidate) != 0) {
            g_rw_lock_writer_unlock(&ss_font_config_lock);
            return 1;
        }
        memcpy(ss_font_environment_id, candidate, sizeof(ss_font_environment_id));
        ss_font_environment_generation = ss_font_config_generation;
        ss_font_environment_valid = 1;
    }
    memcpy(output->id, ss_font_environment_id, sizeof(output->id));
    output->generation = ss_font_config_generation;
    g_rw_lock_writer_unlock(&ss_font_config_lock);
    return 0;
}

int ss_font_environment_refresh(SsFontEnvironment *output) {
    if (output == NULL) return 1;
    g_mutex_lock(&ss_font_registration_mutex);
    g_rw_lock_writer_lock(&ss_font_config_lock);

    int failed = 0;
    PangoFcFontMap *font_map = NULL;
    FcConfig *config = ss_sync_thread_pango_font_config_writer_locked(&font_map);
    unsigned char candidate[SS_FONT_ENVIRONMENT_ID_SIZE];
    int have_candidate = 0;
    int reload = config == NULL || font_map == NULL;
    FcConfig *current = FcConfigReference(NULL);
    if (current == NULL || current != config) reload = 1;
    if (current != NULL) FcConfigDestroy(current);
    if (!reload && FcConfigUptoDate(config) != FcTrue) reload = 1;
    if (!reload) {
        have_candidate = ss_compute_font_environment_writer_locked(candidate) == 0;
        if (!have_candidate) {
            reload = 1;
        } else if (
            ss_font_environment_valid &&
            ss_font_environment_generation == ss_font_config_generation &&
            memcmp(candidate, ss_font_environment_id, sizeof(candidate)) != 0
        ) {
            reload = 1;
        }
    }
    if (reload) {
        if (font_map == NULL || ss_reload_font_config_writer_locked(font_map, candidate) != 0) {
            failed = 1;
        } else {
            have_candidate = 1;
        }
    }
    if (!failed && !have_candidate) {
        have_candidate = ss_compute_font_environment_writer_locked(candidate) == 0;
        if (!have_candidate) failed = 1;
    }
    if (!failed) {
        memcpy(ss_font_environment_id, candidate, sizeof(ss_font_environment_id));
        ss_font_environment_generation = ss_font_config_generation;
        ss_font_environment_valid = 1;
        memcpy(output->id, ss_font_environment_id, sizeof(output->id));
        output->generation = ss_font_config_generation;
    }

    g_rw_lock_writer_unlock(&ss_font_config_lock);
    g_mutex_unlock(&ss_font_registration_mutex);
    return failed;
}

/* Returns with the reader lock held. The caller must release it after the
 * Pango operation has finished. A stale thread-local font map is synchronized
 * only while holding the writer lock, then both generations are rechecked. */
static int ss_lock_stable_pango_font_environment_reader(SsFontEnvironment *output) {
    for (;;) {
        g_rw_lock_reader_lock(&ss_font_config_lock);
        if (
            ss_font_environment_valid &&
            ss_font_environment_generation == ss_font_config_generation &&
            ss_thread_font_config_valid &&
            ss_thread_font_config_generation == ss_font_config_generation
        ) {
            if (output != NULL) {
                memcpy(output->id, ss_font_environment_id, sizeof(output->id));
                output->generation = ss_font_config_generation;
            }
            return 0;
        }
        g_rw_lock_reader_unlock(&ss_font_config_lock);

        g_rw_lock_writer_lock(&ss_font_config_lock);
        int failed = ss_sync_thread_pango_font_config_writer_locked(NULL) == NULL;
        if (!failed && (!ss_font_environment_valid || ss_font_environment_generation != ss_font_config_generation)) {
            unsigned char candidate[SS_FONT_ENVIRONMENT_ID_SIZE];
            if (ss_compute_font_environment_writer_locked(candidate) != 0) {
                failed = 1;
            } else {
                memcpy(ss_font_environment_id, candidate, sizeof(ss_font_environment_id));
                ss_font_environment_generation = ss_font_config_generation;
                ss_font_environment_valid = 1;
            }
        }
        g_rw_lock_writer_unlock(&ss_font_config_lock);
        if (failed) return 1;
    }
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
    if (pdf->pdf_cr != NULL) cairo_destroy(pdf->pdf_cr);
    ss_pdf_destroy_font_faces(pdf);
    if (pdf->surface != NULL) cairo_surface_destroy(pdf->surface);
    free(pdf);
}

const char *ss_pdf_status_string(const SsPdf *pdf) {
    if (pdf == NULL) return "invalid PDF renderer";
    if (pdf->error_message[0] != '\0') return pdf->error_message;
    if (pdf->cr != NULL && cairo_status(pdf->cr) != CAIRO_STATUS_SUCCESS) {
        return cairo_status_to_string(cairo_status(pdf->cr));
    }
    if (pdf->surface != NULL && cairo_surface_status(pdf->surface) != CAIRO_STATUS_SUCCESS) {
        return cairo_status_to_string(cairo_surface_status(pdf->surface));
    }
    return cairo_status_to_string(CAIRO_STATUS_SUCCESS);
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
    if (pdf == NULL || pdf->surface == NULL || pdf->pdf_cr == NULL) return 1;
    cairo_surface_finish(pdf->surface);
    if (cairo_status(pdf->pdf_cr) != CAIRO_STATUS_SUCCESS) return 1;
    if (cairo_surface_status(pdf->surface) != CAIRO_STATUS_SUCCESS) return 1;
    return 0;
}

int ss_pdf_begin_item(SsPdf *pdf, const SsLayerEffects *effects) {
    if (pdf == NULL || pdf->cr == NULL) return 1;
    if (effects == NULL) {
        ss_pdf_set_error(pdf, "missing item effects");
        return 1;
    }
    if (pdf->item_active) {
        ss_pdf_set_error(pdf, "nested PDF item");
        return 1;
    }
    if (effects->opacity < 0 || effects->opacity > 1) {
        ss_pdf_set_error(pdf, "invalid item opacity");
        return 1;
    }
    cairo_save(pdf->cr);
    pdf->item_opacity = effects->opacity;
    pdf->item_blend_mode = effects->blend_mode;
    pdf->item_active = 1;
    cairo_matrix_t matrix;
    cairo_matrix_init(
        &matrix,
        effects->xx,
        effects->yx,
        effects->xy,
        effects->yy,
        effects->x0,
        effects->y0
    );
    cairo_transform(pdf->cr, &matrix);
    if (effects->has_clip) {
        cairo_rectangle(
            pdf->cr,
            effects->clip_x,
            effects->clip_y,
            effects->clip_width,
            effects->clip_height
        );
        cairo_clip(pdf->cr);
    }
    if (effects->opacity != 1 || effects->blend_mode != 0) cairo_push_group(pdf->cr);
    return cairo_status(pdf->cr) == CAIRO_STATUS_SUCCESS ? 0 : 1;
}

int ss_pdf_end_item(SsPdf *pdf) {
    if (pdf == NULL || pdf->cr == NULL) return 1;
    if (!pdf->item_active) {
        ss_pdf_set_error(pdf, "PDF item is not active");
        return 1;
    }
    if (pdf->item_opacity != 1 || pdf->item_blend_mode != 0) {
        cairo_pop_group_to_source(pdf->cr);
        cairo_set_operator(pdf->cr, ss_pdf_blend_operator(pdf->item_blend_mode));
        cairo_paint_with_alpha(pdf->cr, pdf->item_opacity);
    }
    cairo_restore(pdf->cr);
    pdf->item_active = 0;
    return cairo_status(pdf->cr) == CAIRO_STATUS_SUCCESS ? 0 : 1;
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

void ss_pdf_state_save(SsPdf *pdf) {
    if (pdf == NULL || pdf->cr == NULL) return;
    cairo_save(pdf->cr);
}

void ss_pdf_state_restore(SsPdf *pdf) {
    if (pdf == NULL || pdf->cr == NULL) return;
    cairo_restore(pdf->cr);
}

void ss_pdf_path_new(SsPdf *pdf) {
    if (pdf == NULL || pdf->cr == NULL) return;
    cairo_new_path(pdf->cr);
}

void ss_pdf_path_move_to(SsPdf *pdf, double x, double y) {
    if (pdf == NULL || pdf->cr == NULL) return;
    cairo_move_to(pdf->cr, x, y);
}

void ss_pdf_path_line_to(SsPdf *pdf, double x, double y) {
    if (pdf == NULL || pdf->cr == NULL) return;
    cairo_line_to(pdf->cr, x, y);
}

void ss_pdf_path_curve_to(SsPdf *pdf, double x1, double y1, double x2, double y2, double x3, double y3) {
    if (pdf == NULL || pdf->cr == NULL) return;
    cairo_curve_to(pdf->cr, x1, y1, x2, y2, x3, y3);
}

void ss_pdf_path_close(SsPdf *pdf) {
    if (pdf == NULL || pdf->cr == NULL) return;
    cairo_close_path(pdf->cr);
}

static cairo_fill_rule_t ss_pdf_fill_rule(int fill_rule) {
    return fill_rule == 1 ? CAIRO_FILL_RULE_EVEN_ODD : CAIRO_FILL_RULE_WINDING;
}

static cairo_extend_t ss_pdf_gradient_extend(int spread) {
    switch (spread) {
        case 1: return CAIRO_EXTEND_REPEAT;
        case 2: return CAIRO_EXTEND_REFLECT;
        default: return CAIRO_EXTEND_PAD;
    }
}

static void ss_pdf_add_gradient_stops(
    cairo_pattern_t *pattern,
    const double *offsets,
    const double *colors,
    size_t stop_count,
    double alpha
) {
    if (pattern == NULL || offsets == NULL || colors == NULL) return;
    for (size_t index = 0; index < stop_count; index++) {
        cairo_pattern_add_color_stop_rgba(
            pattern,
            offsets[index],
            colors[index * 3],
            colors[index * 3 + 1],
            colors[index * 3 + 2],
            alpha
        );
    }
}

void ss_pdf_path_clip(SsPdf *pdf, int fill_rule) {
    if (pdf == NULL || pdf->cr == NULL) return;
    cairo_set_fill_rule(pdf->cr, ss_pdf_fill_rule(fill_rule));
    cairo_clip(pdf->cr);
}

void ss_pdf_path_fill_solid(SsPdf *pdf, double r, double g, double b, double alpha, int fill_rule) {
    if (pdf == NULL || pdf->cr == NULL) return;
    cairo_set_source_rgba(pdf->cr, r, g, b, alpha);
    cairo_set_fill_rule(pdf->cr, ss_pdf_fill_rule(fill_rule));
    cairo_fill(pdf->cr);
}

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
) {
    if (pdf == NULL || pdf->cr == NULL) return;
    cairo_pattern_t *pattern = cairo_pattern_create_linear(x1, y1, x2, y2);
    if (pattern == NULL) return;
    ss_pdf_add_gradient_stops(pattern, offsets, colors, stop_count, alpha);
    cairo_pattern_set_extend(pattern, ss_pdf_gradient_extend(spread));
    cairo_set_source(pdf->cr, pattern);
    cairo_set_fill_rule(pdf->cr, ss_pdf_fill_rule(fill_rule));
    cairo_fill(pdf->cr);
    cairo_pattern_destroy(pattern);
}

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
) {
    if (pdf == NULL || pdf->cr == NULL) return;
    cairo_pattern_t *pattern = cairo_pattern_create_radial(x1, y1, radius1, x2, y2, radius2);
    if (pattern == NULL) return;
    ss_pdf_add_gradient_stops(pattern, offsets, colors, stop_count, alpha);
    cairo_pattern_set_extend(pattern, ss_pdf_gradient_extend(spread));
    cairo_set_source(pdf->cr, pattern);
    cairo_set_fill_rule(pdf->cr, ss_pdf_fill_rule(fill_rule));
    cairo_fill(pdf->cr);
    cairo_pattern_destroy(pattern);
}

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
) {
    if (pdf == NULL || pdf->cr == NULL) return;
    cairo_set_source_rgba(pdf->cr, r, g, b, alpha);
    cairo_set_line_width(pdf->cr, line_width);
    cairo_set_line_cap(pdf->cr, line_cap == 1 ? CAIRO_LINE_CAP_ROUND : (line_cap == 2 ? CAIRO_LINE_CAP_SQUARE : CAIRO_LINE_CAP_BUTT));
    cairo_set_line_join(pdf->cr, line_join == 1 ? CAIRO_LINE_JOIN_ROUND : (line_join == 2 ? CAIRO_LINE_JOIN_BEVEL : CAIRO_LINE_JOIN_MITER));
    cairo_set_miter_limit(pdf->cr, miter_limit);
    cairo_set_dash(pdf->cr, dashes, (int)dash_count, dash_offset);
    cairo_stroke(pdf->cr);
    cairo_set_dash(pdf->cr, NULL, 0, 0);
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

    cairo_font_face_t *cairo_face = NULL;
    cairo_glyph_t *cairo_glyphs = NULL;
    cairo_text_cluster_t *cairo_clusters = NULL;
    int result = 1;

    cairo_face = ss_pdf_font_face(pdf, font_path, font_index);
    if (cairo_face == NULL) goto cleanup;

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

typedef struct SsThreadTextContext {
    cairo_surface_t *surface;
    cairo_t *cr;
} SsThreadTextContext;

static void ss_thread_text_context_destroy(void *opaque) {
    SsThreadTextContext *context = (SsThreadTextContext *)opaque;
    if (context == NULL) return;
    if (context->cr != NULL) cairo_destroy(context->cr);
    if (context->surface != NULL) cairo_surface_destroy(context->surface);
    free(context);
}

static GPrivate ss_thread_text_context_key = G_PRIVATE_INIT(ss_thread_text_context_destroy);

static cairo_t *ss_thread_text_measure_context(void) {
    SsThreadTextContext *context = (SsThreadTextContext *)g_private_get(&ss_thread_text_context_key);
    if (context != NULL && context->cr != NULL && cairo_status(context->cr) == CAIRO_STATUS_SUCCESS) return context->cr;
    if (context != NULL) {
        g_private_set(&ss_thread_text_context_key, NULL);
        ss_thread_text_context_destroy(context);
    }

    context = (SsThreadTextContext *)calloc(1, sizeof(SsThreadTextContext));
    if (context == NULL) return NULL;
    context->surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, 1, 1);
    if (context->surface == NULL || cairo_surface_status(context->surface) != CAIRO_STATUS_SUCCESS) {
        ss_thread_text_context_destroy(context);
        return NULL;
    }
    context->cr = cairo_create(context->surface);
    if (context->cr == NULL || cairo_status(context->cr) != CAIRO_STATUS_SUCCESS) {
        ss_thread_text_context_destroy(context);
        return NULL;
    }
    g_private_set(&ss_thread_text_context_key, context);
    return context->cr;
}

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

static void ss_font_source_set_outputs(
    const SsFontSource *source,
    char **path_out,
    unsigned int *index_out,
    char **postscript_name_out,
    int *synthetic_bold_out,
    int *synthetic_italic_out
) {
    *path_out = g_strdup(source != NULL && source->path != NULL ? source->path : "");
    *index_out = source != NULL ? source->index : 0;
    *postscript_name_out = g_strdup(source != NULL && source->postscript_name != NULL ? source->postscript_name : "");
    *synthetic_bold_out = source != NULL ? source->synthetic_bold : 0;
    *synthetic_italic_out = source != NULL ? source->synthetic_italic : 0;
}

static void ss_font_source_read_pattern(SsFontSource *source, FcPattern *pattern) {
    if (source == NULL || pattern == NULL) return;
    FcChar8 *path = NULL;
    int index = 0;
    FcChar8 *postscript_name = NULL;
    if (FcPatternGetString(pattern, FC_FILE, 0, &path) == FcResultMatch && path != NULL) {
        gchar *resolved_path = ss_font_config_path(ss_font_config, (const char *)path);
        g_free(source->path);
        source->path = resolved_path != NULL ? resolved_path : g_strdup("");
    }
    if (FcPatternGetInteger(pattern, FC_INDEX, 0, &index) == FcResultMatch && index >= 0) {
        source->index = (unsigned int)index;
    }
    if (FcPatternGetString(pattern, FC_POSTSCRIPT_NAME, 0, &postscript_name) == FcResultMatch && postscript_name != NULL) {
        g_free(source->postscript_name);
        source->postscript_name = g_strdup((const char *)postscript_name);
    }
    FcBool embolden = FcFalse;
    if (FcPatternGetBool(pattern, FC_EMBOLDEN, 0, &embolden) == FcResultMatch) {
        source->synthetic_bold = embolden == FcTrue;
    }
    FcMatrix *matrix = NULL;
    if (FcPatternGetMatrix(pattern, FC_MATRIX, 0, &matrix) == FcResultMatch && matrix != NULL) {
        source->synthetic_italic = matrix->xy != 0 || matrix->yx != 0;
    }
}

static char *ss_font_source_cache_key(const PangoFontDescription *description) {
    if (description == NULL) return NULL;
    const char *family = pango_font_description_get_family(description);
    PangoFontDescription *key = pango_font_description_new();
    if (key == NULL) return NULL;
    pango_font_description_set_family(key, family != NULL ? family : "");
    pango_font_description_set_weight(key, pango_font_description_get_weight(description));
    pango_font_description_set_style(key, pango_font_description_get_style(description));
    pango_font_description_set_stretch(key, pango_font_description_get_stretch(description));
    char *text = pango_font_description_to_string(key);
    pango_font_description_free(key);
    return text;
}

static int ss_font_source_fc_width(PangoStretch stretch) {
    switch (stretch) {
        case PANGO_STRETCH_ULTRA_CONDENSED: return FC_WIDTH_ULTRACONDENSED;
        case PANGO_STRETCH_EXTRA_CONDENSED: return FC_WIDTH_EXTRACONDENSED;
        case PANGO_STRETCH_CONDENSED: return FC_WIDTH_CONDENSED;
        case PANGO_STRETCH_SEMI_CONDENSED: return FC_WIDTH_SEMICONDENSED;
        case PANGO_STRETCH_SEMI_EXPANDED: return FC_WIDTH_SEMIEXPANDED;
        case PANGO_STRETCH_EXPANDED: return FC_WIDTH_EXPANDED;
        case PANGO_STRETCH_EXTRA_EXPANDED: return FC_WIDTH_EXTRAEXPANDED;
        case PANGO_STRETCH_ULTRA_EXPANDED: return FC_WIDTH_ULTRAEXPANDED;
        default: return FC_WIDTH_NORMAL;
    }
}

static void ss_font_source_copy_fallback(
    const PangoFontDescription *description,
    char **path_out,
    unsigned int *index_out,
    char **postscript_name_out,
    int *synthetic_bold_out,
    int *synthetic_italic_out
) {
    char *cache_key = ss_font_source_cache_key(description);
    if (cache_key == NULL) {
        ss_font_source_set_outputs(NULL, path_out, index_out, postscript_name_out, synthetic_bold_out, synthetic_italic_out);
        return;
    }

    g_mutex_lock(&ss_font_source_cache_mutex);
    if (ss_font_source_cache == NULL) {
        ss_font_source_cache = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, ss_font_source_destroy);
    }
    SsFontSource *source = ss_font_source_cache != NULL
        ? (SsFontSource *)g_hash_table_lookup(ss_font_source_cache, cache_key)
        : NULL;
    if (source == NULL) {
        source = g_new0(SsFontSource, 1);
        source->path = g_strdup("");
        source->postscript_name = g_strdup("");
        const char *family = pango_font_description_get_family(description);
        FcPattern *query = FcPatternCreate();
        if (query != NULL) {
            if (family != NULL) FcPatternAddString(query, FC_FAMILY, (const FcChar8 *)family);
            FcPatternAddInteger(query, FC_WEIGHT, FcWeightFromOpenTypeDouble((double)pango_font_description_get_weight(description)));
            FcPatternAddInteger(query, FC_WIDTH, ss_font_source_fc_width(pango_font_description_get_stretch(description)));
            const PangoStyle style = pango_font_description_get_style(description);
            FcPatternAddInteger(query, FC_SLANT, style == PANGO_STYLE_NORMAL ? FC_SLANT_ROMAN : (style == PANGO_STYLE_ITALIC ? FC_SLANT_ITALIC : FC_SLANT_OBLIQUE));
            FcConfigSubstitute(ss_font_config, query, FcMatchPattern);
            FcDefaultSubstitute(query);
            FcResult result = FcResultNoMatch;
            FcPattern *match = FcFontMatch(ss_font_config, query, &result);
            FcPatternDestroy(query);
            ss_font_source_read_pattern(source, match);
            if (match != NULL) FcPatternDestroy(match);
        }
        if (ss_font_source_cache != NULL) {
            if (g_hash_table_size(ss_font_source_cache) >= SS_FONT_SOURCE_CACHE_MAX_ENTRIES) {
                g_hash_table_remove_all(ss_font_source_cache);
            }
            g_hash_table_insert(ss_font_source_cache, g_strdup(cache_key), source);
        }
    }
    ss_font_source_set_outputs(source, path_out, index_out, postscript_name_out, synthetic_bold_out, synthetic_italic_out);
    g_mutex_unlock(&ss_font_source_cache_mutex);
    g_free(cache_key);
}

static void ss_font_source_copy(
    PangoFont *font,
    char **path_out,
    unsigned int *index_out,
    char **postscript_name_out,
    int *synthetic_bold_out,
    int *synthetic_italic_out
) {
    if (font == NULL) {
        ss_font_source_set_outputs(NULL, path_out, index_out, postscript_name_out, synthetic_bold_out, synthetic_italic_out);
        return;
    }
    if (PANGO_IS_FC_FONT(font)) {
        SsFontSource source = {0};
        source.path = g_strdup("");
        source.postscript_name = g_strdup("");
        ss_font_source_read_pattern(&source, pango_fc_font_get_pattern(PANGO_FC_FONT(font)));
        ss_font_source_set_outputs(&source, path_out, index_out, postscript_name_out, synthetic_bold_out, synthetic_italic_out);
        g_free(source.path);
        g_free(source.postscript_name);
        return;
    }
    PangoFontDescription *description = pango_font_describe(font);
    ss_font_source_copy_fallback(description, path_out, index_out, postscript_name_out, synthetic_bold_out, synthetic_italic_out);
    if (description != NULL) pango_font_description_free(description);
}

static double ss_math_constant_ratio(hb_font_t *font, hb_ot_math_constant_t constant, double font_size) {
    return ((double)hb_ot_math_get_constant(font, constant) / PANGO_SCALE) / font_size;
}

static void ss_font_math_constants(PangoFont *font, double font_size, SsMathConstants *output) {
    if (font == NULL || output == NULL || font_size <= 0) return;
    memset(output, 0, sizeof(*output));
    hb_font_t *hb_font = pango_font_get_hb_font(font);
    if (hb_font == NULL || !hb_ot_math_has_data(hb_font_get_face(hb_font))) return;
    output->has_data = 1;
    output->script_scale = (double)hb_ot_math_get_constant(hb_font, HB_OT_MATH_CONSTANT_SCRIPT_PERCENT_SCALE_DOWN) / 100;
    output->script_script_scale = (double)hb_ot_math_get_constant(hb_font, HB_OT_MATH_CONSTANT_SCRIPT_SCRIPT_PERCENT_SCALE_DOWN) / 100;
    output->axis_height = ss_math_constant_ratio(hb_font, HB_OT_MATH_CONSTANT_AXIS_HEIGHT, font_size);
    output->subscript_shift_down = ss_math_constant_ratio(hb_font, HB_OT_MATH_CONSTANT_SUBSCRIPT_SHIFT_DOWN, font_size);
    output->subscript_top_max = ss_math_constant_ratio(hb_font, HB_OT_MATH_CONSTANT_SUBSCRIPT_TOP_MAX, font_size);
    output->subscript_baseline_drop_min = ss_math_constant_ratio(hb_font, HB_OT_MATH_CONSTANT_SUBSCRIPT_BASELINE_DROP_MIN, font_size);
    output->superscript_shift_up = ss_math_constant_ratio(hb_font, HB_OT_MATH_CONSTANT_SUPERSCRIPT_SHIFT_UP, font_size);
    output->superscript_bottom_min = ss_math_constant_ratio(hb_font, HB_OT_MATH_CONSTANT_SUPERSCRIPT_BOTTOM_MIN, font_size);
    output->superscript_baseline_drop_max = ss_math_constant_ratio(hb_font, HB_OT_MATH_CONSTANT_SUPERSCRIPT_BASELINE_DROP_MAX, font_size);
    output->sub_superscript_gap_min = ss_math_constant_ratio(hb_font, HB_OT_MATH_CONSTANT_SUB_SUPERSCRIPT_GAP_MIN, font_size);
    output->superscript_bottom_max_with_subscript = ss_math_constant_ratio(hb_font, HB_OT_MATH_CONSTANT_SUPERSCRIPT_BOTTOM_MAX_WITH_SUBSCRIPT, font_size);
    output->space_after_script = ss_math_constant_ratio(hb_font, HB_OT_MATH_CONSTANT_SPACE_AFTER_SCRIPT, font_size);
    output->fraction_numerator_shift_up = ss_math_constant_ratio(hb_font, HB_OT_MATH_CONSTANT_FRACTION_NUMERATOR_SHIFT_UP, font_size);
    output->fraction_numerator_display_shift_up = ss_math_constant_ratio(hb_font, HB_OT_MATH_CONSTANT_FRACTION_NUMERATOR_DISPLAY_STYLE_SHIFT_UP, font_size);
    output->fraction_denominator_shift_down = ss_math_constant_ratio(hb_font, HB_OT_MATH_CONSTANT_FRACTION_DENOMINATOR_SHIFT_DOWN, font_size);
    output->fraction_denominator_display_shift_down = ss_math_constant_ratio(hb_font, HB_OT_MATH_CONSTANT_FRACTION_DENOMINATOR_DISPLAY_STYLE_SHIFT_DOWN, font_size);
    output->fraction_numerator_gap_min = ss_math_constant_ratio(hb_font, HB_OT_MATH_CONSTANT_FRACTION_NUMERATOR_GAP_MIN, font_size);
    output->fraction_numerator_display_gap_min = ss_math_constant_ratio(hb_font, HB_OT_MATH_CONSTANT_FRACTION_NUM_DISPLAY_STYLE_GAP_MIN, font_size);
    output->fraction_rule_thickness = ss_math_constant_ratio(hb_font, HB_OT_MATH_CONSTANT_FRACTION_RULE_THICKNESS, font_size);
    output->fraction_denominator_gap_min = ss_math_constant_ratio(hb_font, HB_OT_MATH_CONSTANT_FRACTION_DENOMINATOR_GAP_MIN, font_size);
    output->fraction_denominator_display_gap_min = ss_math_constant_ratio(hb_font, HB_OT_MATH_CONSTANT_FRACTION_DENOM_DISPLAY_STYLE_GAP_MIN, font_size);
    output->radical_vertical_gap = ss_math_constant_ratio(hb_font, HB_OT_MATH_CONSTANT_RADICAL_VERTICAL_GAP, font_size);
    output->radical_display_vertical_gap = ss_math_constant_ratio(hb_font, HB_OT_MATH_CONSTANT_RADICAL_DISPLAY_STYLE_VERTICAL_GAP, font_size);
    output->radical_rule_thickness = ss_math_constant_ratio(hb_font, HB_OT_MATH_CONSTANT_RADICAL_RULE_THICKNESS, font_size);
    output->radical_extra_ascender = ss_math_constant_ratio(hb_font, HB_OT_MATH_CONSTANT_RADICAL_EXTRA_ASCENDER, font_size);
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
) {
    if (text == NULL || measurement == NULL || font_size <= 0) return 1;
    memset(measurement, 0, sizeof(*measurement));
    if (ss_lock_stable_pango_font_environment_reader(NULL) != 0) return 1;
    cairo_t *cr = ss_thread_text_measure_context();
    if (cr == NULL) {
        g_rw_lock_reader_unlock(&ss_font_config_lock);
        return 1;
    }
    PangoLayout *layout = pango_cairo_create_layout(cr);
    if (layout == NULL) {
        g_rw_lock_reader_unlock(&ss_font_config_lock);
        return 1;
    }
    PangoFontDescription *description = ss_font_description(font_family, font_weight, font_style, font_stretch, font_size);
    if (description == NULL) {
        g_object_unref(layout);
        g_rw_lock_reader_unlock(&ss_font_config_lock);
        return 1;
    }
    pango_layout_set_font_description(layout, description);
    pango_font_description_free(description);
    char *valid_text = g_utf8_make_valid(text, -1);
    if (valid_text == NULL) {
        g_object_unref(layout);
        g_rw_lock_reader_unlock(&ss_font_config_lock);
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

    PangoRectangle ink = {0};
    PangoRectangle logical = {0};
    pango_layout_get_extents(layout, &ink, &logical);
    measurement->ink_bounds = ss_pango_extents(ink);
    measurement->logical_bounds = ss_pango_extents(logical);
    measurement->first_baseline = ((double)pango_layout_get_baseline(layout)) / PANGO_SCALE;
    g_object_unref(layout);
    g_rw_lock_reader_unlock(&ss_font_config_lock);
    return 0;
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
    if (ss_lock_stable_pango_font_environment_reader(&shape->environment) != 0) return 1;
    cairo_t *cr = ss_thread_text_measure_context();
    if (cr == NULL) {
        g_rw_lock_reader_unlock(&ss_font_config_lock);
        return 1;
    }
    PangoLayout *layout = pango_cairo_create_layout(cr);
    if (layout == NULL) {
        g_rw_lock_reader_unlock(&ss_font_config_lock);
        return 1;
    }
    PangoFontDescription *description = ss_font_description(font_family, font_weight, font_style, font_stretch, font_size);
    if (description == NULL) {
        g_object_unref(layout);
        g_rw_lock_reader_unlock(&ss_font_config_lock);
        return 1;
    }
    pango_layout_set_font_description(layout, description);
    pango_font_description_free(description);
    char *valid_text = g_utf8_make_valid(text, -1);
    if (valid_text == NULL) {
        g_object_unref(layout);
        g_rw_lock_reader_unlock(&ss_font_config_lock);
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
        g_rw_lock_reader_unlock(&ss_font_config_lock);
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
        g_rw_lock_reader_unlock(&ss_font_config_lock);
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
                    run->underline_position = ((double)pango_font_metrics_get_underline_position(metrics)) / PANGO_SCALE;
                    run->underline_thickness = ((double)pango_font_metrics_get_underline_thickness(metrics)) / PANGO_SCALE;
                    run->strikethrough_position = ((double)pango_font_metrics_get_strikethrough_position(metrics)) / PANGO_SCALE;
                    run->strikethrough_thickness = ((double)pango_font_metrics_get_strikethrough_thickness(metrics)) / PANGO_SCALE;
                    pango_font_metrics_unref(metrics);
                }
                ss_font_math_constants(item->analysis.font, font_size, &run->math);
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
    g_rw_lock_reader_unlock(&ss_font_config_lock);
    return 0;
}

double ss_text_measure_text(const char *text, const char *font_family, int font_weight, int font_style, int font_stretch, double font_size) {
    if (ss_lock_stable_pango_font_environment_reader(NULL) != 0) return 0;
    const double width = ss_measure_text_on_cairo(ss_thread_text_measure_context(), text, font_family, font_weight, font_style, font_stretch, font_size, 0);
    g_rw_lock_reader_unlock(&ss_font_config_lock);
    return width;
}

double ss_text_measure_text_visual_width(const char *text, const char *font_family, int font_weight, int font_style, int font_stretch, double font_size) {
    if (ss_lock_stable_pango_font_environment_reader(NULL) != 0) return 0;
    const double width = ss_measure_text_on_cairo(ss_thread_text_measure_context(), text, font_family, font_weight, font_style, font_stretch, font_size, 1);
    g_rw_lock_reader_unlock(&ss_font_config_lock);
    return width;
}
