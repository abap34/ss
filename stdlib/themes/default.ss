import std:themes/base as *

fn/! h1(title_text: String) -> Object
  let title = title_obj(title_text)
  txt(title, "Helvetica-Bold", 30, 36, c"0.07,0.08,0.10", 40, 72, 72)
  return title
end

fn/! h2(subtitle_text: String) -> Object
  let subtitle = sub_obj(subtitle_text)
  txt(subtitle, "Helvetica-Bold", 20, 26, c"0.10,0.11,0.13", 30, 96, 96)
  return subtitle
end

fn/! head(title_text: String) -> Object
  let rule = rule()
  let title = tl(title_obj(title_text), 72, 62)
  txt(title, "Helvetica-Bold", 28, 34, c"0.07,0.08,0.10", 28, 72, 72)
  rule_l(rule, c"0.66,0.70,0.76", 0.9, "")
  rule.layout_spacing_after = 32
  pin_l(rule, 72)
  pin_r(rule, 72)
  below(rule, title, 16)
  return title
end

fn/! subhead(subtitle_text: String) -> Object
  let subtitle = tspan(sub_obj(subtitle_text), 96, 96, 108)
  txt(subtitle, "Helvetica-Bold", 18, 24, c"0.10,0.11,0.13", 30, 96, 96)
  subtitle.text_cjk_bold_passes = 3
  subtitle.text_cjk_bold_dx = 0.04
  return subtitle
end

fn/! text(text_value: String) -> Object
  let body = body_obj(text_value)
  md_code(body, 15, 20, 12, 10, c"0.97,0.98,0.99", c"0.84,0.86,0.90", 0.8, 6)
  return body
end

fn/! tex(text_value: String, scale: Number = 1) -> Object
  let obj = frame(text_value, "math", "math_tex", 96, 96, 8, 8, c"1,1,1", c"0.86,0.88,0.92", 0.7, 6)
  obj.render_kind = RenderKind.vector_math
  obj.text_parse = TextParseMode.none
  obj.math_scale = scale
  return obj
end

fn/! code(text_value: String, language_name: String = "python") -> Object
  return code_box(text_value, language_name, 96, 96, 12, 10, c"0.97,0.98,0.99", c"0.84,0.86,0.90", 0.8, 6)
end

fn toc(title_text: String) -> Object
  let title = head(title_text)
  let list = toc_obj()
  let chrome = panel()
  box(chrome, c"1,1,1", c"0.84,0.86,0.90", 0.8, 6)
  surround(chrome, list, 10, 8)
  return group(title, list)
end

fn toc!(title_text: String) -> Object
  let contents = place!(toc(title_text))
  pageno!()
  return contents
end

fn/! cover(title_text: String, subtitle_text: String, author_name: String) -> Object
  let title = tl(title_obj(title_text), 72, 156)
  let subtitle = sub_obj(subtitle_text)
  let author = by_obj(author_name)
  txt(title, "Helvetica-Bold", 48, 56, c"0.07,0.08,0.10", 24, 72, 72)
  txt(subtitle, "Helvetica", 22, 30, c"0.24,0.27,0.32", 22, 72, 72)
  txt(author, "Helvetica", 18, 24, c"0.36,0.40,0.46", 18, 72, 72)

  below_l(subtitle, title, 0, 24)
  below_l(author, subtitle, 0, 34)
  return title
end
