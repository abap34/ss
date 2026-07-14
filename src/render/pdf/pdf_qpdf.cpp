#include "pdf.h"

#include <qpdf/QPDF.hh>
#include <qpdf/QPDFMatrix.hh>
#include <qpdf/QPDFPageDocumentHelper.hh>
#include <qpdf/QPDFPageObjectHelper.hh>
#include <qpdf/QPDFWriter.hh>

#include <exception>
#include <memory>
#include <string>
#include <unordered_map>
#include <vector>

static thread_local std::string ss_qpdf_error;

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

static QPDFPageObjectHelper ss_qpdf_selected_page(QPDF& pdf, size_t page_index, int box) {
    auto pages = QPDFPageDocumentHelper::get(pdf).getAllPages();
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
        std::vector<std::unique_ptr<QPDF>> sources;
        sources.reserve(input_count);
        for (size_t index = 0; index < input_count; ++index) {
            if (inputs[index] == nullptr) throw std::runtime_error("null PDF input path");
            stage = "read PDF merge input";
            sources.push_back(std::make_unique<QPDF>());
            auto& source = *sources.back();
            source.setSuppressWarnings(true);
            source.processFile(inputs[index]);
            stage = "copy PDF merge pages";
            auto pages = QPDFPageDocumentHelper::get(source).getAllPages();
            if (single_page_inputs) {
                if (pages.empty()) throw std::runtime_error("single-page PDF merge input has no pages");
                destination_pages.addPage(pages.at(0), false);
            } else {
                for (auto& page: pages) destination_pages.addPage(page, false);
            }
        }
        stage = "write merged PDF";
        QPDFWriter writer(destination, output);
        writer.setStaticID(true);
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
        writer.setStaticID(true);
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
        QPDF pdf;
        pdf.processFile(path);
        auto page = ss_qpdf_selected_page(pdf, page_index, box);
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
        QPDF pdf;
        pdf.processFile(path);
        auto pages = QPDFPageDocumentHelper::get(pdf).getAllPages();
        if (pages.size() != page_count) {
            throw std::runtime_error(
                "PDF page count does not match requested geometry count: " +
                std::to_string(pages.size()) + " != " + std::to_string(page_count)
            );
        }
        for (size_t index = 0; index < page_count; ++index) {
            auto page = ss_qpdf_selected_page(pdf, index, box);
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
        auto destination_pages = QPDFPageDocumentHelper::get(destination).getAllPages();
        if (destination_pages.size() != 1) throw std::runtime_error("base PDF layer must contain one page");
        auto destination_page = destination_pages.at(0);
        std::vector<std::unique_ptr<QPDF>> sources;
        sources.reserve(layer_count - 1);
        std::unordered_map<std::string, QPDF*> sources_by_path;

        for (size_t index = 1; index < layer_count; ++index) {
            stage = "validate PDF layer";
            auto const& layer = layers[index];
            if (layer.path == nullptr || layer.width <= 0 || layer.height <= 0) {
                throw std::runtime_error("invalid PDF layer");
            }
            stage = "read PDF layer";
            QPDF* source_pointer = nullptr;
            auto source_it = sources_by_path.find(layer.path);
            if (source_it == sources_by_path.end()) {
                sources.push_back(std::make_unique<QPDF>());
                source_pointer = sources.back().get();
                source_pointer->setSuppressWarnings(true);
                source_pointer->processFile(layer.path);
                sources_by_path.emplace(layer.path, source_pointer);
            } else {
                source_pointer = source_it->second;
            }
            auto& source = *source_pointer;
            stage = "select PDF layer page";
            auto source_page = ss_qpdf_selected_page(source, layer.page_index, layer.box);
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
            destination_page.addPageContents(destination.newStream("q\n"), true);
            destination_page.addPageContents(destination.newStream("\nQ\n" + content), false);
            if (layer.copy_annotations) {
                stage = "copy PDF annotations";
                destination_page.copyAnnotations(source_page, matrix);
            }
        }

        stage = "write composed PDF";
        QPDFWriter writer(destination, output);
        writer.setStaticID(true);
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
