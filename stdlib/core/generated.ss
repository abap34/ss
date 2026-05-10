import std:core/render
import std:core/selectors

fn page_number_object() -> object
  let page_no = object("", "page_number", "text")
  text_preset(page_no, "Helvetica", "13", "16", "0.5,0.5,0.5", "0", "60", "24")
  set_prop(page_no, "wrap", "off")
  overflow_error(page_no)
  right_inset(page_no, 24)
  bottom_inset(page_no, 20)
  return page_no
end

@pass(resolve)
fn refresh_page_numbers(doc: code<document>) -> code<document> ! ReadGraph | WriteContent
  foreach(objects_in_document(doc, "page_number"), refresh_page_number, doc)
  return doc
end

fn refresh_page_number(page_no: object, doc: code<document>) -> object
  let page = parent_page(page_no)
  let text = concat(str(page_index(page)), concat("/", str(page_count(doc))))
  set_content(page_no, text)
  return page_no
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
