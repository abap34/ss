import std:core/render
import std:core/selectors

fn pageno_s(page_no: object) -> object
  txt(page_no, "Helvetica", "13", "16", "0.5,0.5,0.5", "0", "60", "24")
  set_prop(page_no, "wrap", "off")
  fit_error(page_no)
  pin_r(page_no, 24)
  pin_b(page_no, 20)
  return page_no
end

fn pageno_obj() -> object
  return pageno_s(obj("", "pageno", "text"))
end

fn pagenos(format: string = "") -> void
  set_prop(docctx(), "pageno_on", "true")
  set_prop(docctx(), "pageno_fmt", format)
  mk_pagenos(docctx())
  set_pagenos(docctx())
end

fn footers(text_value: string) -> void
  set_prop(docctx(), "footer_text", text_value)
  mk_footers(docctx())
end

fn logos(path_value: string, scale: number = 1) -> void
  set_prop(docctx(), "logo_path", path_value)
  set_prop(docctx(), "logo_scale", scale)
  mk_logos(docctx())
end

fn watermark(text_value: string) -> void
  set_prop(docctx(), "watermark", text_value)
  mk_marks(docctx())
end

fn need_titles() -> void
  set_prop(docctx(), "need_titles", "true")
  chk_titles(docctx())
end

fn mk_pagenos(doc: document) -> void
  if prop_eq(doc, "pageno_on", "true")
    foreach(pages(doc), mk_pageno)
  end
end

fn mk_pageno(page: page) -> page
  if selection_empty(objs(page, "pageno"))
    let page_no = new_object(page, "", "pageno", "text")
    pageno_s(page_no)
  end
  return page
end

fn set_pagenos(doc: document) -> void
  foreach(
    doc_objs(doc, "pageno"),
    (page_no: object) |-> set_pageno(page_no, doc)
  )
end

fn set_pageno(page_no: object, doc: document) -> object
  let page = page_of(page_no)
  if prop_eq(doc, "pageno_fmt", "")
    set_content(page_no, str(page_index(page)) ++ "/" ++ str(page_count(doc)))
  else
    let format = prop(doc, "pageno_fmt", "")
    let page_text = replace(format, "{page}", str(page_index(page)))
    let text = replace(page_text, "{total}", str(page_count(doc)))
    set_content(page_no, text)
  end
  return page_no
end

fn mk_footers(doc: document) -> void
  if has_prop(doc, "footer_text")
    foreach(
      pages(doc),
      (page: page) |-> mk_footer(page, doc)
    )
  end
end

fn mk_footer(page: page, doc: document) -> page
  if selection_empty(objs(page, "footer"))
    let footer = new_object(page, prop(doc, "footer_text", ""), "footer", "text")
    txt(footer, "Helvetica", "12", "15", "0.42,0.42,0.42", "0", "72", "160")
    set_prop(footer, "wrap", "off")
    pin_l(footer, 72)
    pin_b(footer, 20)
  end
  return page
end

fn mk_logos(doc: document) -> void
  if has_prop(doc, "logo_path")
    foreach(
      pages(doc),
      (page: page) |-> mk_logo(page, doc)
    )
  end
end

fn mk_logo(page: page, doc: document) -> page
  if selection_empty(objs(page, "logo"))
    let logo = new_object(page, prop(doc, "logo_path", ""), "logo", "image_ref")
    set_prop(logo, "render_kind", "raster_asset")
    set_prop(logo, "asset_scale", prop(doc, "logo_scale", "1"))
    set_prop(logo, "wrap", "off")
    fix_w(logo, 96)
    fix_h(logo, 40)
    pin_r(logo, 72)
    pin_t(logo, 36)
  end
  return page
end

fn mk_marks(doc: document) -> void
  if has_prop(doc, "watermark")
    foreach(
      pages(doc),
      (page: page) |-> mk_mark(page, doc)
    )
  end
end

fn mk_mark(page: page, doc: document) -> page
  if selection_empty(objs(page, "watermark"))
    let mark = new_object(page, prop(doc, "watermark", ""), "watermark", "text")
    txt(mark, "Helvetica", "72", "80", "0.85,0.85,0.85", "0", "0", "0")
    set_prop(mark, "wrap", "off")
    fix_w(mark, 800)
    fix_h(mark, 90)
    equal(anchor(mark, "center_x"), page_anchor("center_x"), 0)
    equal(anchor(mark, "center_y"), page_anchor("center_y"), 0)
  end
  return page
end

fn toc_obj() -> object
  let toc = obj("", "toc", "text")
  txt(toc, "Helvetica", "18", "24", "0,0,0.0353", "24", "96", "96")
  set_toc(toc, docctx())
  return toc
end

fn set_tocs(doc: document) -> void
  foreach(
    doc_objs(doc, "toc"),
    (toc: object) |-> set_toc(toc, doc)
  )
end

fn toc_row(title: object, page: page) -> string
  return "- " ++ content(title) ++ " .... " ++ str(page_index(page)) ++ "\n"
end

fn toc_text(doc: document) -> string
  return "Table of Contents\n" ++ join(
    pages(doc),
    "",
    (page: page) |->
      join(
        objs(page, "title"),
        "",
        (title: object) |-> toc_row(title, page)
      )
  )
end

fn set_toc(toc: object, doc: document) -> object
  set_content(toc, toc_text(doc))
  return toc
end

fn chk_titles(doc: document) -> void
  if prop_eq(doc, "need_titles", "true")
    foreach(pages(doc), warn_title)
  end
end

fn warn_title(page: page) -> page
  if selection_empty(objs(page, "title"))
    report_warning("MissingTitle: page has no title object")
  end
  return page
end
