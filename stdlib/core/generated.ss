import std:core/render as *
import std:core/selectors as *

fn pageno_s(page_no: Object) -> Object
  apply_text(page_no, TextStyle {
    font = FontFace { family = "Helvetica" }
    size = 13
    line_height = 16
    color = c"0.5,0.5,0.5"
  })
  apply_layout(page_no, LayoutStyle {
    spacing_after = 0
    x = 60
    right_inset = 24
    wrap = WrapMode.off
    fit = FitPolicy.error
  })
  pin_r(page_no, 24)
  pin_b(page_no, 20)
  return page_no
end

fn/! pageno_obj() -> Object
  return pageno_s(obj("", "pageno", "text"))
end

fn pagenos!(format: String? = none) -> Void
  mk_pagenos!(docctx(), format)
end

fn footers!(text_value: String) -> Void
  mk_footers!(docctx(), text_value)
end

fn logos!(path_value: String, scale: Number = 1) -> Void
  mk_logos!(docctx(), path_value, scale)
end

fn watermark!(text_value: String) -> Void
  mk_marks!(docctx(), text_value)
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
    doc_objs(docctx(), numbered_item_role(counter_name)),
    set_numbered_item,
    format
  )
end

fn mk_pagenos!(doc: Document, format: String?) -> Void
  foreach(pages(doc), (page_value: Page) |-> mk_pageno!(page_value, doc, format))
end

fn mk_pageno!(page_value: Page, doc: Document, format: String?) -> Page
  let page_no = place_on!(page_value, new("", "pageno", "text"))
  pageno_s(page_no)
  set_pageno(page_no, doc, format)
  return page_value
end

fn set_pagenos(doc: Document) -> Void
  foreach(
    doc_objs(doc, "pageno"),
    (page_no: Object) |-> set_pageno(page_no, doc, none)
  )
end

fn set_pageno(page_no: Object, doc: Document, format: String?) -> Object
  set_prop(page_no, "pageno_format", format)
  return set_repr(page_no, pageno_repr)
end

fn pageno_repr(page_no: Object) -> String
  let page_value = page_of(page_no)
  if page_no.pageno_format?
    let format_text = page_no.pageno_format ?? ""
    let page_text = replace(format_text, "{page}", str(page_index(page_value)))
    return replace(page_text, "{total}", str(page_count(docctx())))
  end
  return str(page_index(page_value)) ++ "/" ++ str(page_count(docctx()))
end

fn mk_footers!(doc: Document, text_value: String) -> Void
  foreach(
    pages(doc),
    (page_value: Page) |-> mk_footer!(page_value, text_value)
  )
end

fn mk_footer!(page_value: Page, text_value: String) -> Page
  let footer = place_on!(page_value, new(text_value, "footer", "text"))
  apply_text(footer, TextStyle {
    font = FontFace { family = "Helvetica" }
    size = 12
    line_height = 15
    color = c"0.42,0.42,0.42"
  })
  apply_layout(footer, LayoutStyle {
    spacing_after = 0
    x = 72
    right_inset = 160
    wrap = WrapMode.off
  })
  pin_l(footer, 72)
  pin_b(footer, 20)
  return page_value
end

fn mk_logos!(doc: Document, path_value: String, scale: Number) -> Void
  foreach(
    pages(doc),
    (page_value: Page) |-> mk_logo!(page_value, path_value, scale)
  )
end

fn mk_logo!(page_value: Page, path_value: String, scale: Number) -> Page
  let logo = place_on!(page_value, new(path_value, "logo", "image_ref"))
  logo.render_kind = RenderKind.raster_asset
  logo.asset_scale = scale
  logo.wrap = WrapMode.off
  fix_w(logo, 96)
  fix_h(logo, 40)
  pin_r(logo, 72)
  pin_t(logo, 36)
  return page_value
end

fn mk_marks!(doc: Document, text_value: String) -> Void
  foreach(
    pages(doc),
    (page_value: Page) |-> mk_mark!(page_value, text_value)
  )
end

fn mk_mark!(page_value: Page, text_value: String) -> Page
  let mark = place_on!(page_value, new(text_value, "watermark", "text"))
  apply_text(mark, TextStyle {
    font = FontFace { family = "Helvetica" }
    size = 72
    line_height = 80
    color = c"0.85,0.85,0.85"
  })
  apply_layout(mark, LayoutStyle {
    spacing_after = 0
    x = 0
    right_inset = 0
    wrap = WrapMode.off
  })
  fix_w(mark, 800)
  fix_h(mark, 90)
  equal(anchor(mark, "center_x"), page_anchor("center_x"), 0)
  equal(anchor(mark, "center_y"), page_anchor("center_y"), 0)
  return page_value
end

fn toc_obj() -> Object
  let toc = obj("", "toc", "text")
  return set_repr(toc, toc_repr)
end

fn set_tocs(doc: Document) -> Void
  foreach(
    doc_objs(doc, "toc"),
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
    pages(doc),
    "",
    (page_value: Page) |->
      join(
        objs(page_value, "title"),
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
  foreach(pages(doc), warn_title)
end

fn warn_title(page_value: Page) -> Page
  if selection_empty(objs(page_value, "title"))
    report_warning("MissingTitle: Page has no title object")
  end
  return page_value
end
