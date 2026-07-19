// qpdf 11 requires an explicit opt-in to the shared-pointer API that qpdf 12 uses by default.
#define POINTERHOLDER_TRANSITION 4

#include "backend.h"

#include <qpdf/QPDF.hh>
#include <qpdf/QPDFMatrix.hh>
#include <qpdf/QPDFPageDocumentHelper.hh>
#include <qpdf/QPDFPageObjectHelper.hh>
#include <qpdf/QPDFWriter.hh>

#include <exception>
#include <cmath>
#include <cctype>
#include <memory>
#include <stdexcept>
#include <string>
#include <unordered_map>
#include <vector>

static thread_local std::string ss_qpdf_error;

struct SsQpdfDocument {
    explicit SsQpdfDocument(char const* path, bool suppress_warnings = false) {
        if (suppress_warnings) pdf.setSuppressWarnings(true);
        pdf.processFile(path);
        QPDFPageDocumentHelper page_document(pdf);
        pages = page_document.getAllPages();
    }

    QPDF pdf;
    std::vector<QPDFPageObjectHelper> pages;
};

static bool ss_qpdf_finite(double value) {
    return std::isfinite(value);
}

static bool ss_qpdf_valid_effects(SsLayerEffects const& effects) {
    return ss_qpdf_finite(effects.xx) && ss_qpdf_finite(effects.yx) &&
        ss_qpdf_finite(effects.xy) && ss_qpdf_finite(effects.yy) &&
        ss_qpdf_finite(effects.x0) && ss_qpdf_finite(effects.y0) &&
        ss_qpdf_finite(effects.opacity) && effects.opacity >= 0 && effects.opacity <= 1 &&
        effects.blend_mode >= 0 && effects.blend_mode <= 5 &&
        (effects.has_clip == 0 ||
         (ss_qpdf_finite(effects.clip_x) && ss_qpdf_finite(effects.clip_y) &&
          ss_qpdf_finite(effects.clip_width) && ss_qpdf_finite(effects.clip_height) &&
          effects.clip_width >= 0 && effects.clip_height >= 0));
}

static char const* ss_qpdf_blend_mode(int blend_mode) {
    switch (blend_mode) {
    case 1: return "/Multiply";
    case 2: return "/Screen";
    case 3: return "/Overlay";
    case 4: return "/Darken";
    case 5: return "/Lighten";
    default: return "/Normal";
    }
}

static QPDFMatrix ss_qpdf_combined_matrix(QPDFMatrix const& outer, QPDFMatrix const& inner) {
    return {
        outer.a * inner.a + outer.c * inner.b,
        outer.b * inner.a + outer.d * inner.b,
        outer.a * inner.c + outer.c * inner.d,
        outer.b * inner.c + outer.d * inner.d,
        outer.a * inner.e + outer.c * inner.f + outer.e,
        outer.b * inner.e + outer.d * inner.f + outer.f,
    };
}

static std::string ss_qpdf_real(double value) {
    return QPDFObjectHandle::newReal(value, 12).unparse();
}

extern "C" char const* ss_qpdf_version_string(void) {
    return QPDF::QPDFVersion().c_str();
}

static QPDFObjectHandle ss_qpdf_page_box(QPDFPageObjectHelper& page, int box) {
    switch (box) {
    case 0:
        return page.getMediaBox();
    case 2:
        return page.getBleedBox();
    case 3:
        return page.getTrimBox();
    case 4:
        return page.getArtBox();
    case 1:
    default:
        return page.getCropBox();
    }
}

static QPDFPageObjectHelper ss_qpdf_selected_page(
    std::vector<QPDFPageObjectHelper> const& pages,
    size_t page_index,
    int box
) {
    if (page_index >= pages.size()) throw std::runtime_error("PDF page index is out of range");
    auto page = pages.at(page_index);
    auto selected_box = ss_qpdf_page_box(page, box);
    page.getObjectHandle().replaceKey("/TrimBox", selected_box.shallowCopy());
    return page;
}

static QPDFObjectHandle::Rectangle ss_qpdf_visible_form_box(QPDFPageObjectHelper& page) {
    auto form = page.getFormXObjectForPage();
    auto dictionary = form.getDict();
    auto rectangle = dictionary.getKey("/BBox").getArrayAsRectangle();
    auto matrix = dictionary.getKey("/Matrix");
    if (matrix.isArray()) rectangle = QPDFMatrix(matrix.getArrayAsMatrix()).transformRectangle(rectangle);
    return rectangle;
}

extern "C" int ss_qpdf_merge(
    char const* output,
    char const* const* inputs,
    size_t input_count,
    int single_page_inputs
) {
    ss_qpdf_error.clear();
    if (output == nullptr || (input_count != 0 && inputs == nullptr)) {
        ss_qpdf_error = "invalid PDF merge arguments";
        return 1;
    }
    char const* stage = "create PDF merge destination";
    try {
        QPDF destination;
        destination.emptyPDF();
        QPDFPageDocumentHelper destination_pages(destination);
        std::vector<std::unique_ptr<SsQpdfDocument>> sources;
        sources.reserve(input_count);
        for (size_t index = 0; index < input_count; ++index) {
            if (inputs[index] == nullptr) throw std::runtime_error("null PDF input path");
            stage = "read PDF merge input";
            sources.push_back(std::make_unique<SsQpdfDocument>(inputs[index], true));
            auto& source = *sources.back();
            stage = "copy PDF merge pages";
            if (single_page_inputs) {
                if (source.pages.empty()) {
                    throw std::runtime_error("single-page PDF merge input has no pages");
                }
                destination_pages.addPage(source.pages.at(0), false);
            } else {
                for (auto& page: source.pages) destination_pages.addPage(page, false);
            }
        }
        stage = "write merged PDF";
        QPDFWriter writer(destination, output);
        writer.setDeterministicID(true);
        writer.write();
        return 0;
    } catch (std::exception const& error) {
        ss_qpdf_error = std::string(stage) + ": " + error.what();
    } catch (...) {
        ss_qpdf_error = std::string(stage) + ": libqpdf failed with an unknown exception";
    }
    return 1;
}

extern "C" int ss_qpdf_empty(char const* output) {
    ss_qpdf_error.clear();
    if (output == nullptr) {
        ss_qpdf_error = "null PDF output path";
        return 1;
    }
    try {
        QPDF pdf;
        pdf.emptyPDF();
        QPDFWriter writer(pdf, output);
        writer.setDeterministicID(true);
        writer.write();
        return 0;
    } catch (std::exception const& error) {
        ss_qpdf_error = error.what();
    } catch (...) {
        ss_qpdf_error = "libqpdf failed with an unknown exception";
    }
    return 1;
}

extern "C" int ss_qpdf_page_size(
    char const* path,
    size_t page_index,
    int box,
    double* width,
    double* height
) {
    ss_qpdf_error.clear();
    try {
        if (path == nullptr) throw std::runtime_error("null PDF input path");
        SsQpdfDocument source(path);
        auto page = ss_qpdf_selected_page(source.pages, page_index, box);
        auto rectangle = ss_qpdf_visible_form_box(page);
        const double page_width = rectangle.urx - rectangle.llx;
        const double page_height = rectangle.ury - rectangle.lly;
        if (page_width <= 0 || page_height <= 0) throw std::runtime_error("PDF page has an invalid page box");
        if (width != nullptr) *width = page_width;
        if (height != nullptr) *height = page_height;
        return 0;
    } catch (std::exception const& error) {
        ss_qpdf_error = error.what();
    } catch (...) {
        ss_qpdf_error = "libqpdf failed with an unknown exception";
    }
    return 1;
}

extern "C" int ss_qpdf_page_sizes(
    char const* path,
    int box,
    double* widths,
    double* heights,
    size_t page_count
) {
    ss_qpdf_error.clear();
    try {
        if (path == nullptr || widths == nullptr || heights == nullptr) {
            throw std::runtime_error("invalid PDF page geometry arguments");
        }
        SsQpdfDocument source(path);
        if (source.pages.size() != page_count) {
            throw std::runtime_error(
                "PDF page count does not match requested geometry count: " +
                std::to_string(source.pages.size()) + " != " + std::to_string(page_count)
            );
        }
        for (size_t index = 0; index < page_count; ++index) {
            auto page = ss_qpdf_selected_page(source.pages, index, box);
            auto rectangle = ss_qpdf_visible_form_box(page);
            widths[index] = rectangle.urx - rectangle.llx;
            heights[index] = rectangle.ury - rectangle.lly;
            if (widths[index] <= 0 || heights[index] <= 0) {
                throw std::runtime_error("PDF page has an invalid page box");
            }
        }
        return 0;
    } catch (std::exception const& error) {
        ss_qpdf_error = error.what();
    } catch (...) {
        ss_qpdf_error = "libqpdf failed with an unknown exception";
    }
    return 1;
}

static bool ss_qpdf_has_javascript(QPDF& pdf) {
    auto root = pdf.getRoot();
    auto names = root.getKey("/Names");
    if (names.isDictionary() && !names.getKey("/JavaScript").isNull()) return true;
    auto open_action = root.getKey("/OpenAction");
    return open_action.isDictionary() && open_action.getKey("/S").isName() &&
        open_action.getKey("/S").getName() == "/JavaScript";
}

static bool ss_qpdf_safe_uri(std::string const& value) {
    for (unsigned char byte: value) if (byte < 0x20 || byte == 0x7f) return false;
    auto colon = value.find(':');
    if (colon == std::string::npos) return true;
    auto path_separator = value.find_first_of("/?#");
    if (path_separator != std::string::npos && colon > path_separator) return true;
    std::string scheme = value.substr(0, colon);
    for (char& byte: scheme) byte = static_cast<char>(std::tolower(static_cast<unsigned char>(byte)));
    return scheme == "http" || scheme == "https" || scheme == "mailto";
}

static bool ss_qpdf_safe_link_annotation(QPDFObjectHandle annotation) {
    if (!annotation.isDictionary()) return false;
    auto subtype = annotation.getKey("/Subtype");
    if (!subtype.isName() || subtype.getName() != "/Link") return false;
    if (!annotation.getKey("/AA").isNull() || !annotation.getKey("/PA").isNull()) return false;
    auto action = annotation.getKey("/A");
    if (action.isNull()) return !annotation.getKey("/Dest").isNull();
    if (!action.isDictionary() || !action.getKey("/Next").isNull()) return false;
    auto kind = action.getKey("/S");
    if (!kind.isName()) return false;
    if (kind.getName() == "/GoTo") return !action.getKey("/D").isNull();
    if (kind.getName() != "/URI") return false;
    auto uri = action.getKey("/URI");
    return uri.isString() && ss_qpdf_safe_uri(uri.getUTF8Value());
}

static bool ss_qpdf_unsafe_annotations(QPDFPageObjectHelper& page) {
    auto annotations = page.getObjectHandle().getKey("/Annots");
    if (!annotations.isArray()) return false;
    for (auto annotation: annotations.getArrayAsVector()) {
        if (!ss_qpdf_safe_link_annotation(annotation)) return true;
    }
    return false;
}

static QPDFObjectHandle ss_qpdf_sanitized_action(QPDFObjectHandle action) {
    auto result = QPDFObjectHandle::newDictionary();
    auto kind = action.getKey("/S");
    result.replaceKey("/S", kind.shallowCopy());
    if (kind.getName() == "/URI") {
        result.replaceKey("/URI", action.getKey("/URI").shallowCopy());
        auto is_map = action.getKey("/IsMap");
        if (is_map.isBool()) result.replaceKey("/IsMap", is_map.shallowCopy());
    } else {
        result.replaceKey("/D", action.getKey("/D").shallowCopy());
    }
    return result;
}

static void ss_qpdf_copy_safe_annotations(
    QPDFPageObjectHelper& destination_page,
    QPDFPageObjectHelper& source_page,
    QPDFMatrix const& matrix
) {
    auto source_object = source_page.getObjectHandle();
    auto annotations = source_object.getKey("/Annots");
    if (!annotations.isArray()) return;
    auto sanitized = QPDFObjectHandle::newArray();
    for (auto annotation: annotations.getArrayAsVector()) {
        if (!ss_qpdf_safe_link_annotation(annotation)) continue;
        auto copy = annotation.shallowCopy();
        copy.removeKey("/AA");
        copy.removeKey("/PA");
        copy.removeKey("/QuadPoints");
        auto action = annotation.getKey("/A");
        if (action.isDictionary()) copy.replaceKey("/A", ss_qpdf_sanitized_action(action));
        sanitized.appendItem(copy);
    }
    if (sanitized.getArrayNItems() == 0) return;
    source_object.replaceKey("/Annots", sanitized);
    try {
        destination_page.copyAnnotations(source_page, matrix);
        source_object.replaceKey("/Annots", annotations);
    } catch (...) {
        source_object.replaceKey("/Annots", annotations);
        throw;
    }
}

extern "C" int ss_qpdf_metadata(
    char const* path,
    SsPdfDocumentMetadata* document,
    SsPdfPageMetadata* page_metadata,
    size_t page_capacity
) {
    ss_qpdf_error.clear();
    try {
        if (path == nullptr || document == nullptr) throw std::runtime_error("invalid PDF metadata arguments");
        SsQpdfDocument source(path, true);
        document->page_count = source.pages.size();
        document->encrypted = source.pdf.isEncrypted() ? 1 : 0;
        document->has_javascript = ss_qpdf_has_javascript(source.pdf) ? 1 : 0;
        if (page_capacity == 0) return 0;
        if (page_metadata == nullptr || page_capacity < source.pages.size()) {
            throw std::runtime_error("PDF metadata page buffer is too small");
        }
        for (size_t page_index = 0; page_index < source.pages.size(); ++page_index) {
            auto& page = source.pages.at(page_index);
            auto& metadata = page_metadata[page_index];
            for (int box = 0; box < 5; ++box) {
                auto rectangle = ss_qpdf_page_box(page, box).getArrayAsRectangle();
                metadata.boxes[box][0] = rectangle.llx;
                metadata.boxes[box][1] = rectangle.lly;
                metadata.boxes[box][2] = rectangle.urx;
                metadata.boxes[box][3] = rectangle.ury;
            }
            auto object = page.getObjectHandle();
            auto user_unit = object.getKey("/UserUnit");
            metadata.user_unit = user_unit.isNumber() ? user_unit.getNumericValue() : 1.0;
            auto rotation = object.getKey("/Rotate");
            int normalized_rotation = rotation.isInteger() ? rotation.getIntValue() % 360 : 0;
            if (normalized_rotation < 0) normalized_rotation += 360;
            metadata.rotation = normalized_rotation;
            auto annotations = object.getKey("/Annots");
            metadata.annotation_count = annotations.isArray() ? annotations.getArrayNItems() : 0;
            metadata.has_unsafe_annotations = ss_qpdf_unsafe_annotations(page) ? 1 : 0;
        }
        return 0;
    } catch (std::exception const& error) {
        ss_qpdf_error = error.what();
    } catch (...) {
        ss_qpdf_error = "libqpdf failed with an unknown exception";
    }
    return 1;
}

extern "C" int ss_qpdf_compose(char const* output, SsQpdfLayer const* layers, size_t layer_count) {
    ss_qpdf_error.clear();
    char const* stage = "validate composition arguments";
    try {
        if (output == nullptr || layers == nullptr || layer_count == 0 || layers[0].path == nullptr) {
            throw std::runtime_error("invalid PDF composition arguments");
        }

        stage = "read base PDF layer";
        QPDF destination;
        destination.setSuppressWarnings(true);
        destination.processFile(layers[0].path);
        QPDFPageDocumentHelper destination_page_document(destination);
        auto destination_pages = destination_page_document.getAllPages();
        if (destination_pages.size() != 1) throw std::runtime_error("base PDF layer must contain one page");
        auto destination_page = destination_pages.at(0);
        std::vector<std::unique_ptr<SsQpdfDocument>> sources;
        sources.reserve(layer_count - 1);
        std::unordered_map<std::string, SsQpdfDocument*> sources_by_path;

        for (size_t index = 1; index < layer_count; ++index) {
            stage = "validate PDF layer";
            auto const& layer = layers[index];
            if (layer.path == nullptr || layer.width <= 0 || layer.height <= 0 ||
                !ss_qpdf_valid_effects(layer.effects)) {
                throw std::runtime_error("invalid PDF layer");
            }
            stage = "read PDF layer";
            SsQpdfDocument* source_pointer = nullptr;
            auto source_it = sources_by_path.find(layer.path);
            if (source_it == sources_by_path.end()) {
                sources.push_back(std::make_unique<SsQpdfDocument>(layer.path, true));
                source_pointer = sources.back().get();
                sources_by_path.emplace(layer.path, source_pointer);
            } else {
                source_pointer = source_it->second;
            }
            stage = "select PDF layer page";
            auto source_page = ss_qpdf_selected_page(
                source_pointer->pages,
                layer.page_index,
                layer.box
            );
            stage = "create PDF form";
            auto foreign_form = source_page.getFormXObjectForPage();
            stage = "copy PDF form";
            auto form = destination.copyForeignObject(foreign_form);
            stage = "prepare destination resources";
            auto resources = destination_page.getAttribute("/Resources", true);
            int minimum_suffix = 1;
            auto name = resources.getUniqueResourceName("/SsLayer", minimum_suffix);
            QPDFMatrix matrix;
            stage = "place PDF form";
            auto content = destination_page.placeFormXObject(
                form,
                name,
                {layer.x, layer.y, layer.x + layer.width, layer.y + layer.height},
                matrix,
                true,
                true,
                true
            );
            if (content.empty()) throw std::runtime_error("unable to place PDF layer");
            stage = "attach PDF form resources";
            resources.mergeResources("<< /XObject << >> >>"_qpdf);
            resources.getKey("/XObject").replaceKey(name, form);
            auto const& effects = layer.effects;
            QPDFMatrix effect_matrix(
                effects.xx,
                effects.yx,
                effects.xy,
                effects.yy,
                effects.x0,
                effects.y0
            );
            std::string prefix = "q\n";
            if (effects.xx != 1 || effects.yx != 0 || effects.xy != 0 || effects.yy != 1 ||
                effects.x0 != 0 || effects.y0 != 0) {
                prefix += effect_matrix.unparse() + " cm\n";
            }
            if (effects.has_clip) {
                prefix += ss_qpdf_real(effects.clip_x) + " " +
                    ss_qpdf_real(effects.clip_y) + " " +
                    ss_qpdf_real(effects.clip_width) + " " +
                    ss_qpdf_real(effects.clip_height) + " re W n\n";
            }
            if (effects.opacity != 1 || effects.blend_mode != 0) {
                resources.mergeResources("<< /ExtGState << >> >>"_qpdf);
                auto states = resources.getKey("/ExtGState");
                int minimum_state_suffix = 1;
                auto state_name = resources.getUniqueResourceName("/SsState", minimum_state_suffix);
                auto state = QPDFObjectHandle::newDictionary();
                state.replaceKey("/Type", QPDFObjectHandle::newName("/ExtGState"));
                state.replaceKey("/ca", QPDFObjectHandle::newReal(effects.opacity, 12));
                state.replaceKey("/CA", QPDFObjectHandle::newReal(effects.opacity, 12));
                state.replaceKey("/BM", QPDFObjectHandle::newName(ss_qpdf_blend_mode(effects.blend_mode)));
                states.replaceKey(state_name, state);
                prefix += state_name + " gs\n";
            }
            content = prefix + content + "\nQ\n";
            destination_page.addPageContents(destination.newStream("q\n"), true);
            destination_page.addPageContents(destination.newStream("\nQ\n" + content), false);
            if (layer.copy_annotations) {
                stage = "copy PDF annotations";
                ss_qpdf_copy_safe_annotations(destination_page, source_page, ss_qpdf_combined_matrix(effect_matrix, matrix));
            }
        }

        stage = "write composed PDF";
        QPDFWriter writer(destination, output);
        writer.setDeterministicID(true);
        writer.write();
        return 0;
    } catch (std::exception const& error) {
        ss_qpdf_error = std::string(stage) + ": " + error.what();
    } catch (std::string const& error) {
        ss_qpdf_error = std::string(stage) + ": " + error;
    } catch (...) {
        ss_qpdf_error = std::string(stage) + ": libqpdf failed with an unknown exception";
    }
    return 1;
}

extern "C" char const* ss_qpdf_last_error(void) {
    return ss_qpdf_error.c_str();
}
