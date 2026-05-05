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

@phase(after_pages)
fn refresh_page_numbers(doc: document) -> document
  foreach(objects_in_document(doc, "page_number"), refresh_page_number, doc)
  return doc
end

fn refresh_page_number(page_no: object, doc: document) -> object
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

@phase(after_pages)
fn refresh_tocs(doc: document) -> document
  foreach(objects_in_document(doc, "toc"), refresh_toc, doc)
  return doc
end

fn refresh_toc(toc: object, doc: document) -> object
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

fn rewrite_text(base: object, old: string, new: string) -> object
  let obj = derive(base, "rewrite_text", old, new)
  set_prop(obj, "render_kind", "code")
  return obj
end

fn highlight(base: object, note: string) -> object
  let obj = derive(select(base, "self_object"), "highlight", note)
  text_preset(obj, "Helvetica", "14", "18", "1,0.5961,0", "20", "120", "120")
  return obj
end

fn highlight_selection(base: selection<object>, note: string) -> object
  let obj = derive(base, "highlight", note)
  text_preset(obj, "Helvetica", "14", "18", "1,0.5961,0", "20", "120", "120")
  return obj
end
