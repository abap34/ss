import std:themes/base as *

fn body_style(body: Object) -> Object
  txt(body, "Helvetica", 24, 31, c"0.07,0.08,0.10", 28, 96, 96)
  body.text_line_height = 31
  md_bold(body, c"0.05,0.30,0.58")
  md_code(body, 19, 25, 12, 9, c"0.965,0.975,0.988", c"0.78,0.84,0.92", 0.9, 6)
  md_table(body, 12, 9, c"0.76,0.82,0.90", 0.8, c"0.90,0.94,0.98", c"0.985,0.990,0.996")
  return body
end

fn/! h1(title_text: String) -> Object
  let title = title_obj(title_text)
  txt(title, "Helvetica-Bold", 40, 47, c"0.04,0.06,0.09", 42, 72, 72)
  title.text_line_height = 47
  return title
end

fn/! h2(subtitle_text: String) -> Object
  let subtitle = sub_obj(subtitle_text)
  txt(subtitle, "Helvetica-Bold", 30, 37, c"0.07,0.09,0.13", 34, 88, 88)
  subtitle.text_line_height = 37
  return subtitle
end

fn/! h3(subtitle_text: String) -> Object
  let subtitle = sub_obj(subtitle_text)
  txt(subtitle, "Helvetica-Bold", 24, 31, c"0.10,0.12,0.16", 28, 96, 96)
  subtitle.text_line_height = 31
  return subtitle
end

fn/! head(title_text: String) -> Object
  let rule = rule()
  let title = tl(title_obj(title_text), 72, 56)
  txt(title, "Helvetica-Bold", 36, 44, c"0.04,0.06,0.09", 34, 72, 72)
  title.text_line_height = 44
  rule_l(rule, c"0.78,0.84,0.91", 0.8, "")
  rule.layout_spacing_after = 48
  pin_l(rule, 72)
  pin_r(rule, 72)
  below(rule, title, 14)
  return title
end

fn/! subhead(subtitle_text: String) -> Object
  let subtitle = tspan(sub_obj(subtitle_text), 96, 96, 124)
  txt(subtitle, "Helvetica-Bold", 26, 33, c"0.08,0.10,0.14", 30, 96, 96)
  subtitle.text_line_height = 33
  subtitle.text_cjk_bold_passes = 3
  subtitle.text_cjk_bold_dx = 0.04
  return subtitle
end

fn/! text(text_value: String) -> Object
  let body = body_obj(text_value)
  body_style(body)
  return body
end

fn/! note(text_value: String) -> Object
  let note = note_obj(text_value)
  txt(note, "Helvetica", 15, 20, c"0.38,0.42,0.48", 16, 112, 112)
  note.text_line_height = 20
  return note
end

fn/! tex(text_value: String, scale: Number = 1) -> Object
  let obj = frame(text_value, "math", "math_tex", 96, 96, 14, 12, c"0.997,0.999,1.000", c"0.78,0.84,0.92", 0.9, 8)
  obj.render_kind = RenderKind.vector_math
  obj.text_parse = TextParseMode.none
  obj.math_scale = scale
  obj.math_align = Align.center
  return obj
end

fn/! figure(text_value: String) -> Object
  let obj = frame(text_value, "figure", "figure_text", 102, 102, 16, 12, c"0.997,0.999,1.000", c"0.78,0.84,0.92", 0.9, 8)
  body_style(obj)
  return obj
end

fn/! image(path_value: String, factor: Number = 1) -> Object
  let obj = img_obj(path_value)
  flow(obj, 102, 102)
  let chrome = panel()
  box(chrome, c"1,1,1", c"0.78,0.84,0.92", 0.9, 8)
  chrome.layout_spacing_after = 30
  surround(chrome, obj, 12, 10)
  scale(obj, factor)
  require_asset_exists(obj)
  return obj
end

fn/! pdf(path_value: String, factor: Number = 1) -> Object
  let obj = pdf_obj(path_value)
  flow(obj, 102, 102)
  let chrome = panel()
  box(chrome, c"1,1,1", c"0.78,0.84,0.92", 0.9, 8)
  chrome.layout_spacing_after = 30
  surround(chrome, obj, 12, 10)
  scale(obj, factor)
  require_asset_exists(obj)
  return obj
end

fn/! code(text_value: String, language_name: String = "python") -> Object
  let code = code_box(text_value, language_name, 96, 96, 16, 12, c"0.965,0.975,0.988", c"0.78,0.84,0.92", 0.9, 8)
  code.text_size = 16
  code.text_line_height = 22
  code.text_code_font = "Menlo"
  code.layout_spacing_after = 30
  return code
end

fn toc(title_text: String) -> Object
  let title = head(title_text)
  let list = toc_obj()
  body_style(list)
  list.text_size = 18
  list.text_line_height = 25
  let chrome = panel()
  box(chrome, c"1,1,1", c"0.78,0.84,0.92", 0.9, 8)
  below(list, title, title.layout_spacing_after ?? 36)
  surround(chrome, list, 14, 12)
  return group(title, chrome, list)
end

fn toc!(title_text: String) -> Object
  let contents = place!(toc(title_text))
  pageno!()
  return contents
end

fn/! cover(title_text: String, subtitle_text: String, author_name: String) -> Object
  let title = tl(title_obj(title_text), 72, 148)
  let subtitle = sub_obj(subtitle_text)
  let author = by_obj(author_name)
  let accent = rule()
  txt(title, "Helvetica-Bold", 56, 64, c"0.04,0.06,0.09", 26, 72, 72)
  txt(subtitle, "Helvetica", 30, 38, c"0.20,0.25,0.32", 24, 72, 72)
  txt(author, "Helvetica", 20, 26, c"0.38,0.42,0.48", 18, 72, 72)
  title.text_line_height = 64
  subtitle.text_line_height = 38
  author.text_line_height = 26
  rule_l(accent, c"0.32,0.50,0.72", 2.0, "")

  below_l(subtitle, title, 0, 28)
  below_l(author, subtitle, 0, 40)
  pin_l(accent, 72)
  fix_w(accent, 160)
  below(accent, author, 32)
  return title
end
