import std:core/render as *
import std:core/selectors as *

fn pageno_s(page_no: Object) -> Object
  txt(page_no, "Helvetica", 13, 16, c"0.5,0.5,0.5", 0, 60, 24)
  page_no.wrap = WrapMode.off
  fit_error(page_no)
  pin_r(page_no, 24)
  pin_b(page_no, 20)
  return page_no
end

fn/! pageno_obj() -> Object
  return pageno_s(obj("", "pageno", "text"))
end

fn pagenos!(format: String? = none) -> Void
  docctx().pageno_fmt = format
  mk_pagenos!(docctx())
  set_pagenos(docctx())
end

fn footers!(text_value: String) -> Void
  docctx().footer_text = text_value
  mk_footers!(docctx())
end

fn logos!(path_value: String, scale: Number = 1) -> Void
  docctx().logo_path = path_value
  docctx().logo_scale = scale
  mk_logos!(docctx())
end

fn watermark!(text_value: String) -> Void
  docctx().watermark = text_value
  mk_marks!(docctx())
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
  return item
end

fn set_numbered_item(item: Object, index: Number, format: String) -> Object
  let source_text = item.numbered_item_source ?? ""
  let numbered_text = replace(format, "{number}", str(index))
  return set_content(item, replace(numbered_text, "{text}", source_text))
end

fn numbering!(counter_name: String, format: String = "{number}. {text}") -> Void
  foreach_enumerate(
    doc_objs(docctx(), numbered_item_role(counter_name)),
    set_numbered_item,
    format
  )
end

fn mk_pagenos!(doc: Document) -> Void
  foreach(pages(doc), (page_value: Page) |-> mk_pageno!(page_value))
end

fn mk_pageno!(page_value: Page) -> Page
  if selection_empty(objs(page_value, "pageno"))
    let page_no = place_on!(page_value, new("", "pageno", "text"))
    pageno_s(page_no)
  end
  return page_value
end

fn set_pagenos(doc: Document) -> Void
  foreach(
    doc_objs(doc, "pageno"),
    (page_no: Object) |-> set_pageno(page_no, doc)
  )
end

fn set_pageno(page_no: Object, doc: Document) -> Object
  let page_value = page_of(page_no)
  if doc.pageno_fmt?
    let format = doc.pageno_fmt ?? ""
    let page_text = replace(format, "{page}", str(page_index(page_value)))
    let text = replace(page_text, "{total}", str(page_count(doc)))
    page_no.content = text
  else
    page_no.content = str(page_index(page_value)) ++ "/" ++ str(page_count(doc))
  end
  return page_no
end

fn mk_footers!(doc: Document) -> Void
  if doc.footer_text?
    foreach(
      pages(doc),
      (page_value: Page) |-> mk_footer!(page_value, doc)
    )
  end
end

fn mk_footer!(page_value: Page, doc: Document) -> Page
  if selection_empty(objs(page_value, "footer"))
    let footer = place_on!(page_value, new(doc.footer_text ?? "", "footer", "text"))
    txt(footer, "Helvetica", 12, 15, c"0.42,0.42,0.42", 0, 72, 160)
    footer.wrap = WrapMode.off
    pin_l(footer, 72)
    pin_b(footer, 20)
  end
  return page_value
end

fn mk_logos!(doc: Document) -> Void
  if doc.logo_path?
    foreach(
      pages(doc),
      (page_value: Page) |-> mk_logo!(page_value, doc)
    )
  end
end

fn mk_logo!(page_value: Page, doc: Document) -> Page
  if selection_empty(objs(page_value, "logo"))
    let logo = place_on!(page_value, new(doc.logo_path ?? "", "logo", "image_ref"))
    logo.render_kind = RenderKind.raster_asset
    logo.asset_scale = doc.logo_scale ?? 1
    logo.wrap = WrapMode.off
    fix_w(logo, 96)
    fix_h(logo, 40)
    pin_r(logo, 72)
    pin_t(logo, 36)
  end
  return page_value
end

fn mk_marks!(doc: Document) -> Void
  if doc.watermark?
    foreach(
      pages(doc),
      (page_value: Page) |-> mk_mark!(page_value, doc)
    )
  end
end

fn mk_mark!(page_value: Page, doc: Document) -> Page
  if selection_empty(objs(page_value, "watermark"))
    let mark = place_on!(page_value, new(doc.watermark ?? "", "watermark", "text"))
    txt(mark, "Helvetica", 72, 80, c"0.85,0.85,0.85", 0, 0, 0)
    mark.wrap = WrapMode.off
    fix_w(mark, 800)
    fix_h(mark, 90)
    equal(anchor(mark, "center_x"), page_anchor("center_x"), 0)
    equal(anchor(mark, "center_y"), page_anchor("center_y"), 0)
  end
  return page_value
end

fn toc_obj() -> Object
  let toc = obj("", "toc", "text")
  txt(toc, "Helvetica", 18, 24, c"0,0,0.0353", 24, 96, 96)
  set_toc(toc, docctx())
  return toc
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
  toc.content = toc_text(doc)
  return toc
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
