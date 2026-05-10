import std:core/render
import std:core/selectors

fn page_number_preset(page_no: object) -> object
  text_preset(page_no, "Helvetica", "13", "16", "0.5,0.5,0.5", "0", "60", "24")
  set_prop(page_no, "wrap", "off")
  overflow_error(page_no)
  right_inset(page_no, 24)
  bottom_inset(page_no, 20)
  return page_no
end

fn page_number_object() -> object
  return page_number_preset(object("", "page_number", "text"))
end

fn page_numbers(format: string = "") -> document
  set_prop(docctx(), "page_numbers_enabled", "true")
  set_prop(docctx(), "page_numbers_format", format)
  return docctx()
end

fn page_no_all(format: string = "") -> document
  return page_numbers(format)
end

fn running_footer(text_value: string) -> document
  set_prop(docctx(), "running_footer_text", text_value)
  return docctx()
end

fn logo_all(path_value: string, scale: number = 1) -> document
  set_prop(docctx(), "document_logo_path", path_value)
  set_prop(docctx(), "document_logo_scale", scale)
  return docctx()
end

fn watermark(text_value: string) -> document
  set_prop(docctx(), "watermark_text", text_value)
  return docctx()
end

fn require_titles_all() -> document
  set_prop(docctx(), "require_titles_enabled", "true")
  return docctx()
end

@pass(augment)
fn materialize_document_page_numbers(doc: code<document>) -> code<document> ! ReadGraph | CreateNode | WriteContent | WriteProperty | WriteConstraint
  if prop_eq(doc, "page_numbers_enabled", "true")
    foreach(pages(doc), materialize_page_number_for_page)
  end
  return doc
end

fn materialize_page_number_for_page(page: page) -> page
  if selection_empty(objects(page, "page_number"))
    let page_no = new_object(page, "", "page_number", "text")
    page_number_preset(page_no)
  end
  return page
end

@pass(resolve)
fn refresh_page_numbers(doc: code<document>) -> code<document> ! ReadGraph | WriteContent
  foreach(objects_in_document(doc, "page_number"), refresh_page_number, doc)
  return doc
end

fn refresh_page_number(page_no: object, doc: code<document>) -> object
  let page = parent_page(page_no)
  if prop_eq(doc, "page_numbers_format", "")
    set_content(page_no, concat(str(page_index(page)), concat("/", str(page_count(doc)))))
  else
    let format = prop(doc, "page_numbers_format", "")
    let page_text = replace(format, "{page}", str(page_index(page)))
    let text = replace(page_text, "{total}", str(page_count(doc)))
    set_content(page_no, text)
  end
  return page_no
end

@pass(augment)
fn materialize_running_footers(doc: code<document>) -> code<document> ! ReadGraph | CreateNode | WriteContent | WriteProperty | WriteConstraint
  if has_prop(doc, "running_footer_text")
    foreach(pages(doc), materialize_running_footer_for_page, doc)
  end
  return doc
end

fn materialize_running_footer_for_page(page: page, doc: code<document>) -> page
  if selection_empty(objects(page, "running_footer"))
    let footer = new_object(page, prop(doc, "running_footer_text", ""), "running_footer", "text")
    text_preset(footer, "Helvetica", "12", "15", "0.42,0.42,0.42", "0", "72", "160")
    set_prop(footer, "wrap", "off")
    left_inset(footer, 72)
    bottom_inset(footer, 20)
  end
  return page
end

@pass(augment)
fn materialize_document_logos(doc: code<document>) -> code<document> ! ReadGraph | CreateNode | WriteContent | WriteProperty | WriteConstraint
  if has_prop(doc, "document_logo_path")
    foreach(pages(doc), materialize_document_logo_for_page, doc)
  end
  return doc
end

fn materialize_document_logo_for_page(page: page, doc: code<document>) -> page
  if selection_empty(objects(page, "document_logo"))
    let logo = new_object(page, prop(doc, "document_logo_path", ""), "document_logo", "image_ref")
    set_prop(logo, "render_kind", "raster_asset")
    set_prop(logo, "asset_scale", prop(doc, "document_logo_scale", "1"))
    set_prop(logo, "wrap", "off")
    fixed_width(logo, 96)
    fixed_height(logo, 40)
    right_inset(logo, 72)
    top_inset(logo, 36)
  end
  return page
end

@pass(augment)
fn materialize_watermarks(doc: code<document>) -> code<document> ! ReadGraph | CreateNode | WriteContent | WriteProperty | WriteConstraint
  if has_prop(doc, "watermark_text")
    foreach(pages(doc), materialize_watermark_for_page, doc)
  end
  return doc
end

fn materialize_watermark_for_page(page: page, doc: code<document>) -> page
  if selection_empty(objects(page, "watermark"))
    let mark = new_object(page, prop(doc, "watermark_text", ""), "watermark", "text")
    text_preset(mark, "Helvetica", "72", "80", "0.85,0.85,0.85", "0", "0", "0")
    set_prop(mark, "wrap", "off")
    fixed_width(mark, 800)
    fixed_height(mark, 90)
    equal(anchor(mark, "center_x"), page_anchor("center_x"), 0)
    equal(anchor(mark, "center_y"), page_anchor("center_y"), 0)
  end
  return page
end

fn toc_object() -> object
  let toc = object("", "toc", "text")
  text_preset(toc, "Helvetica", "18", "24", "0,0,0.0353", "24", "96", "96")
  return toc
end

fn toc_list_object() -> object
  return toc_object()
end

@pass(resolve)
fn refresh_tocs(doc: code<document>) -> code<document> ! ReadGraph | WriteContent
  foreach(objects_in_document(doc, "toc"), refresh_toc, doc)
  return doc
end

fn refresh_toc(toc: object, doc: code<document>) -> object
  clear_content(toc)
  append_content(toc, "Table of Contents\n")
  foreach(pages(doc), append_toc_page, toc)
  return toc
end

fn append_toc_page(page: page, toc: object) -> page
  foreach(objects(page, "title"), append_toc_title, toc, page)
  return page
end

fn append_toc_title(title: object, toc: object, page: page) -> object
  append_content(toc, concat("- ", concat(content(title), concat(" .... ", concat(str(page_index(page)), "\n")))))
  return title
end

@pass(inspect_layout)
fn inspect_required_titles(doc: code<document>) -> code<document> ! ReadGraph | EmitDiagnostics
  if prop_eq(doc, "require_titles_enabled", "true")
    foreach(pages(doc), report_missing_title)
  end
  return doc
end

fn report_missing_title(page: page) -> page
  if selection_empty(objects(page, "title"))
    report_warning("MissingTitle: page has no title object")
  end
  return page
end
