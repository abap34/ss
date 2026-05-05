import std:core/render

fn page_number_object() -> object @phase(after_pages)
  let page_no = object("", "page_number", "text")
  text_preset(page_no, "Helvetica", "13", "16", "0.5,0.5,0.5", "0", "60", "24")
  set_prop(page_no, "wrap", "off")
  overflow_error(page_no)
  right_inset(page_no, 24)
  bottom_inset(page_no, 20)
  return page_no
end

fn toc_object() -> object @phase(after_pages)
  let toc = object("", "toc", "text")
  text_preset(toc, "Helvetica", "18", "24", "0,0,0.0353", "24", "96", "96")
  return toc
end

fn toc_list_object() -> object
  return toc_object()
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
