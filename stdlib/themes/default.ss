import std:themes/base as *

fn default_code_theme() -> CodeHighlightTheme
  return code_theme_github_light()
end

fn body_style(
  body: Object,
  font_size_name: Number = 24,
  line_height_name: Number = 31,
  color_name: Color = c"0.07,0.08,0.10",
  markdown_bold_color_name: Color = c"0.05,0.30,0.58",
  table_pad_x_name: Number = 12,
  table_pad_y_name: Number = 9,
  table_line_width_name: Number = 0.8
) -> Object
  let theme = default_code_theme()
  let fill = theme.fill ?? c"#f6f8fa"
  let stroke = theme.stroke ?? c"#d0d7de"
  txt(body, "Helvetica", font_size_name, line_height_name, color_name, 28, 96, 96)
  md_bold(body, markdown_bold_color_name)
  md_code(body, 19, 25, 12, 9, docctx().code_theme_fill ?? fill, docctx().code_theme_stroke ?? stroke, 0.9, 6)
  code_theme(body, theme)
  md_table(body, table_pad_x_name, table_pad_y_name, c"0.76,0.82,0.90", table_line_width_name, c"0.90,0.94,0.98", c"0.985,0.990,0.996")
  return body
end

fn/! h1(title_text: String, font_size_name: Number = 40, color_name: Color = c"0.04,0.06,0.09") -> Object
  let title = title_obj(title_text)
  txt(title, "Helvetica", font_size_name, add(font_size_name, 7), color_name, 42, 72, 72, 700)
  return title
end

fn/! h2(subtitle_text: String, font_size_name: Number = 30, color_name: Color = c"0.07,0.09,0.13") -> Object
  let subtitle = sub_obj(subtitle_text)
  txt(subtitle, "Helvetica", font_size_name, add(font_size_name, 7), color_name, 34, 88, 88, 700)
  return subtitle
end

fn/! h3(subtitle_text: String, font_size_name: Number = 24, color_name: Color = c"0.10,0.12,0.16") -> Object
  let subtitle = sub_obj(subtitle_text)
  txt(subtitle, "Helvetica", font_size_name, add(font_size_name, 7), color_name, 28, 96, 96, 700)
  return subtitle
end

fn/! head(title_text: String) -> Object
  let rule = rule()
  let title = tl(title_obj(title_text), 72, 56)
  txt(title, "Helvetica", 36, 44, c"0.04,0.06,0.09", 34, 72, 72, 700)
  rule_l(rule, c"0.78,0.84,0.91", 0.8, "")
  rule.layout_spacing_after = 48
  pin_l(rule, 72)
  pin_r(rule, 72)
  below(rule, title, -4)
  return title
end

fn/! subhead(subtitle_text: String) -> Object
  let subtitle = tspan(sub_obj(subtitle_text), 96, 96, 124)
  txt(subtitle, "Helvetica", 26, 33, c"0.08,0.10,0.14", 30, 96, 96, 700)
  subtitle.text_cjk_bold_passes = 3
  subtitle.text_cjk_bold_dx = 0.04
  return subtitle
end

fn/! text(text_value: String, font_size_name: Number = 24, color_name: Color = c"0.07,0.08,0.10", markdown_bold_color_name: Color = c"0.05,0.30,0.58") -> Object
  let body = body_obj(text_value)
  body_style(body, font_size_name, add(font_size_name, 7), color_name, markdown_bold_color_name)
  return body
end

fn/! note(text_value: String) -> Object
  let note = note_obj(text_value)
  txt(note, "Helvetica", 15, 20, c"0.38,0.42,0.48", 16, 112, 112)
  return note
end

fn/! tex(text_value: String, scale: Number = 1) -> Object
  let obj = flow(tex_obj(text_value), 96, 96)
  obj.math_scale = scale
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
  obj.layout_spacing_after = 30
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

fn/! code(text_value: String, language_name: String = "python", font_size_name: Number = 16, code_font_family_name: String = "Menlo") -> Object
  let theme = default_code_theme()
  let fill = theme.fill ?? c"#f6f8fa"
  let stroke = theme.stroke ?? c"#d0d7de"
  let code = code_box(text_value, language_name, 96, 96, 16, 12, docctx().code_theme_fill ?? fill, docctx().code_theme_stroke ?? stroke, 0.9, 8)
  code_theme(code, theme)
  code.text_size = font_size_name
  code.text_code_font_family = code_font_family_name
  code.layout_spacing_after = 30
  return code
end

fn/! code_file(path_value: String, language_name: String = "plain") -> Object
  return code(readlines(path_value), language_name)
end

fn toc(title_text: String) -> Object
  let title = lab_obj(title_text)
  txt(title, "Helvetica", 36, 44, c"0.04,0.06,0.09", 34, 72, 72, 700)
  let list = toc_obj()
  body_style(list, 18, 25, c"0.07,0.08,0.10")
  let chrome = panel()
  box(chrome, c"1,1,1", c"0.78,0.84,0.92", 0.9, 8)
  below(list, title, 34)
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
  txt(title, "Helvetica", 56, 64, c"0.04,0.06,0.09", 26, 72, 72, 700)
  txt(subtitle, "Helvetica", 30, 38, c"0.20,0.25,0.32", 24, 72, 72)
  txt(author, "Helvetica", 20, 26, c"0.38,0.42,0.48", 18, 72, 72)
  rule_l(accent, c"0.32,0.50,0.72", 2.0, "")

  below_l(subtitle, title, 0, 28)
  below_l(author, subtitle, 0, 40)
  pin_l(accent, 72)
  fix_w(accent, 160)
  below(accent, author, 32)
  return title
end
