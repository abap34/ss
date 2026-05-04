import std:core/render

fn page_number_object() -> object
  let page_no = derive(pagectx(), "page_number")
  overflow_error(page_no)
  return page_no
end

fn toc_object() -> object
  return derive(docctx(), "toc")
end

fn toc_list_object() -> object
  return toc_object()
end

fn rewrite_text(base: object, old: string, new: string) -> object
  return derive(base, "rewrite_text", old, new)
end

fn highlight(base: object, note: string) -> object
  return derive(select(base, "self_object"), "highlight", note)
end

fn highlight_selection(base: selection, note: string) -> object
  return derive(base, "highlight", note)
end
