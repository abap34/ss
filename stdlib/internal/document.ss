import std:internal/classes
import std:internal/objects as objects
import std:query as selectors

fn style_pageno(page_no: Object) -> Object
  page_no.text = TextStyle {
    font = FontFace { family = "Helvetica" }
    size = 13
    line_height = 16
    color = c"0.5,0.5,0.5"
  }
  page_no.layout = LayoutStyle {
    spacing_after = 0
    x = 60
    right_inset = 24
    wrap = WrapMode.off
    fit = FitPolicy.error
  }
  return page_no
end

fn position_pageno(page_value: Page, page_no: Object) -> Object
  page_value ~ page_no.right == page_value.right - 24
  page_value ~ page_no.bottom == page_value.bottom + 20
  return page_no
end

fn pageno_s(page_no: Object) -> Object
  style_pageno(page_no)
  ~ page_no.right == page.right - 24
  ~ page_no.bottom == page.bottom + 20
  return set_pageno(page_no, pagectx(), none)
end

fn/! pageno_obj(decorate: Object -> Object = style_pageno) -> Object
  let page_no = objects::obj("", "pageno", "text")
  decorate(page_no)
  ~ page_no.right == page.right - 24
  ~ page_no.bottom == page.bottom + 20
  return set_pageno(page_no, pagectx(), none)
end

fn pagenos!(format: String? = none) -> Void
  mk_pagenos!(docctx(), format)
end

fn need_titles() -> Void
  chk_titles(docctx())
end

fn numbered_item_role(counter_name: String) -> String
  return "__ss.std.numbered:" ++ counter_name
end

fn/! numbered_item(counter_name: String, text_value: String) -> Object
  let item = new(text_value, numbered_item_role(counter_name), "text")
  item.numbered_item_source = text_value
  return set_repr(item, numbered_item_repr)
end

fn numbered_item_repr(item: Object) -> String
  let source_text = item.numbered_item_source ?? content(item)
  let numbered_text = replace(item.numbered_item_format ?? "{text}", "{number}", item.numbered_item_number ?? "0")
  return replace(numbered_text, "{text}", source_text)
end

fn set_numbered_item(item: Object, index: Number, format: String) -> Object
  item.numbered_item_number = str(index)
  item.numbered_item_format = format
  return item
end

fn numbering!(counter_name: String, format: String = "{number}. {text}") -> Void
  foreach_enumerate(
    selectors::doc_objs(docctx(), numbered_item_role(counter_name)),
    set_numbered_item,
    format
  )
end

fn mk_pagenos!(doc: Document, format: String?, decorate: Object -> Object = style_pageno) -> Void
  foreach(selectors::pages(doc), (page_value: Page) |-> mk_pageno!(page_value, doc, format, decorate))
end

fn mk_pageno!(page_value: Page, doc: Document, format: String?, decorate: Object -> Object = style_pageno) -> Page
  let page_no = place_on!(page_value, new("", "pageno", "text"))
  decorate(page_no)
  position_pageno(page_value, page_no)
  set_pageno(page_no, page_value, format)
  return page_value
end

fn set_pagenos(doc: Document) -> Void
  foreach(
    selectors::pages(doc),
    (page_value: Page) |-> foreach(
      selectors::objs(page_value, "pageno"),
      (page_no: Object) |-> set_pageno(page_no, page_value, none)
    )
  )
end

fn set_pageno(page_no: Object, page_value: Page, format: String?) -> Object
  page_no.pageno_format = format
  return set_repr(page_no, (item: Object) |-> pageno_repr(item, page_value))
end

fn pageno_repr(page_no: Object, page_value: Page) -> String
  if page_no.pageno_format?
    let format_text = page_no.pageno_format ?? ""
    let page_text = replace(format_text, "{page}", str(page_index(page_value)))
    return replace(page_text, "{total}", str(page_count(docctx())))
  end
  return str(page_index(page_value)) ++ "/" ++ str(page_count(docctx()))
end

fn toc_obj() -> Object
  let toc = objects::obj("", "toc", "text")
  return set_repr(toc, toc_repr)
end

fn set_tocs(doc: Document) -> Void
  foreach(
    selectors::doc_objs(doc, "toc"),
    (toc: Object) |-> set_toc(toc, doc)
  )
end

fn toc_row(title: Object, page_value: Page) -> String
  return "- " ++ title.content ++ " .... " ++ str(page_index(page_value)) ++ "
"
end

fn toc_text(doc: Document) -> String
  return "Table of Contents
" ++ join(
    selectors::pages(doc),
    "",
    (page_value: Page) |->
      join(
        selectors::objs(page_value, "title"),
        "",
        (title: Object) |-> toc_row(title, page_value)
      )
  )
end

fn set_toc(toc: Object, doc: Document) -> Object
  return set_repr(toc, toc_repr)
end

fn toc_repr(toc: Object) -> String
  return toc_text(docctx())
end

fn chk_titles(doc: Document) -> Void
  foreach(selectors::pages(doc), warn_title)
end

fn warn_title(page_value: Page) -> Page
  if selection_empty(selectors::objs(page_value, "title"))
    report_warning("MissingTitle: Page has no title object")
  end
  return page_value
end
