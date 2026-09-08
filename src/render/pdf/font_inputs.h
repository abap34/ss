#ifndef SS_FONT_INPUTS_H
#define SS_FONT_INPUTS_H

/* Accessed only while the font configuration writer lock is held. */
#define SS_FONT_INPUT_MAX_ENTRIES 8192
#define SS_FONT_INPUT_MAX_BYTES (8 * 1024 * 1024)

enum SsFontInputList {
    SS_FONT_CONFIG_FILES,
    SS_FONT_DIRECTORIES,
    SS_FONT_SYSTEM_FACES,
    SS_FONT_APPLICATION_FACES,
    SS_FONT_INPUT_LIST_COUNT
};

typedef struct SsFontInputName {
    char *path;
    int face_index;
} SsFontInputName;

typedef struct SsFontInputFile {
    GStatBuf metadata;
    int present;
} SsFontInputFile;

typedef struct SsFontInputs {
    FcConfig *config;
    GPtrArray *lists[SS_FONT_INPUT_LIST_COUNT];
    GHashTable *files;
    unsigned char context[SS_FONT_ENVIRONMENT_ID_SIZE];
    unsigned char digest[SS_FONT_ENVIRONMENT_ID_SIZE];
    size_t entries;
    size_t bytes;
    int cacheable;
} SsFontInputs;

static SsFontInputs ss_cached_font_inputs;

static void ss_font_input_name_destroy(gpointer value) {
    SsFontInputName *name = value;
    g_free(name->path);
    g_free(name);
}

static void ss_font_inputs_clear(SsFontInputs *inputs) {
    for (size_t index = 0; index < SS_FONT_INPUT_LIST_COUNT; index++) {
        if (inputs->lists[index] != NULL) g_ptr_array_unref(inputs->lists[index]);
    }
    if (inputs->files != NULL) g_hash_table_unref(inputs->files);
    memset(inputs, 0, sizeof(*inputs));
}

static void ss_font_inputs_init(SsFontInputs *inputs, FcConfig *config, const unsigned char *context) {
    memset(inputs, 0, sizeof(*inputs));
    inputs->config = config;
    memcpy(inputs->context, context, sizeof(inputs->context));
    inputs->cacheable = 1;
    inputs->files = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, g_free);
    for (size_t index = 0; index < SS_FONT_INPUT_LIST_COUNT; index++) {
        inputs->lists[index] = g_ptr_array_new_with_free_func(ss_font_input_name_destroy);
    }
}

static int ss_font_inputs_reserve(SsFontInputs *inputs, size_t bytes) {
    if (!inputs->cacheable) return 0;
    if (inputs->entries >= SS_FONT_INPUT_MAX_ENTRIES || bytes > SS_FONT_INPUT_MAX_BYTES - inputs->bytes) {
        inputs->cacheable = 0;
        return 0;
    }
    inputs->entries++;
    inputs->bytes += bytes;
    return 1;
}

static void ss_font_inputs_name(SsFontInputs *inputs, enum SsFontInputList list, const char *path, int face_index) {
    if (path == NULL) path = "";
    if (!ss_font_inputs_reserve(inputs, sizeof(SsFontInputName) + strlen(path) + 1)) return;
    SsFontInputName *name = g_new(SsFontInputName, 1);
    name->path = g_strdup(path);
    name->face_index = face_index;
    g_ptr_array_add(inputs->lists[list], name);
}

static void ss_font_inputs_file(SsFontInputs *inputs, const char *path, const GStatBuf *metadata) {
    if (!inputs->cacheable) return;
    SsFontInputFile *previous = g_hash_table_lookup(inputs->files, path);
    if (previous != NULL) {
        if (previous->present != (metadata != NULL) || (metadata != NULL && !ss_stat_matches(&previous->metadata, metadata))) {
            inputs->cacheable = 0;
        }
        return;
    }
    if (!ss_font_inputs_reserve(inputs, sizeof(SsFontInputFile) + strlen(path) + 1)) return;
    SsFontInputFile *file = g_new0(SsFontInputFile, 1);
    file->present = metadata != NULL;
    if (metadata != NULL) file->metadata = *metadata;
    g_hash_table_insert(inputs->files, g_strdup(path), file);
}

static int ss_font_inputs_list_matches(const GPtrArray *expected, FcStrList *actual) {
    guint index = 0;
    int matches = 1;
    FcChar8 *path = NULL;
    while (actual != NULL && (path = FcStrListNext(actual)) != NULL) {
        if (index >= expected->len || strcmp(((SsFontInputName *)expected->pdata[index])->path, (const char *)path) != 0) {
            matches = 0;
            break;
        }
        index++;
    }
    if (actual != NULL) FcStrListDone(actual);
    return matches && index == expected->len;
}

static int ss_font_inputs_faces_match(const GPtrArray *expected, const FcFontSet *actual) {
    const int count = actual != NULL ? actual->nfont : 0;
    if (count < 0 || (guint)count != expected->len) return 0;
    for (int index = 0; index < count; index++) {
        const SsFontInputName *name = expected->pdata[index];
        FcChar8 *path = NULL;
        int face_index = 0;
        if (FcPatternGetString(actual->fonts[index], FC_FILE, 0, &path) != FcResultMatch) path = NULL;
        if (FcPatternGetInteger(actual->fonts[index], FC_INDEX, 0, &face_index) != FcResultMatch) face_index = 0;
        if (name->face_index != face_index || strcmp(name->path, path != NULL ? (const char *)path : "") != 0) return 0;
    }
    return 1;
}

static int ss_font_inputs_match(FcConfig *config, const unsigned char *context) {
    const SsFontInputs *inputs = &ss_cached_font_inputs;
    if (!inputs->cacheable || inputs->config != config || memcmp(inputs->context, context, sizeof(inputs->context)) != 0) return 0;
    if (!ss_font_inputs_list_matches(inputs->lists[SS_FONT_CONFIG_FILES], FcConfigGetConfigFiles(config)) ||
        !ss_font_inputs_list_matches(inputs->lists[SS_FONT_DIRECTORIES], FcConfigGetFontDirs(config)) ||
        !ss_font_inputs_faces_match(inputs->lists[SS_FONT_SYSTEM_FACES], FcConfigGetFonts(config, FcSetSystem)) ||
        !ss_font_inputs_faces_match(inputs->lists[SS_FONT_APPLICATION_FACES], FcConfigGetFonts(config, FcSetApplication))) return 0;
    GHashTableIter iterator;
    gpointer path;
    gpointer value;
    g_hash_table_iter_init(&iterator, inputs->files);
    while (g_hash_table_iter_next(&iterator, &path, &value)) {
        const SsFontInputFile *expected = value;
        GStatBuf metadata;
        if (g_stat(path, &metadata) != 0) {
            if (!expected->present && (errno == ENOENT || errno == ENOTDIR)) continue;
            return 0;
        }
        if (!expected->present || !ss_stat_matches(&expected->metadata, &metadata)) return 0;
    }
    return FcConfigUptoDate(config) == FcTrue;
}

#endif
