import std:themes/base

fn h1(title_text: String) -> Object
  let title_style = style("pop")
  let title = styled(title_text, "title", title_style)
  txt(title, "Helvetica-Bold", "36", "42", "1,0.3765,0.5098", "46", "72", "72")
  return title
end

fn h2(subtitle_text: String) -> Object
  let subtitle = sub_obj(subtitle_text)
  txt(subtitle, "Helvetica", "22", "30", "0.1569,0.1333,0.2196", "22", "78", "78")
  return subtitle
end

fn head(title_text: String) -> Object
  let chip_style = style("pop_chip")
  let title_style = style("pop")
  let chip = styled(title_text, "label", chip_style)
  let title = tl(styled(title_text, "title", title_style), 72, 98)
  txt(chip, "Helvetica-Bold", "13", "18", "1,1,1", "0", "72", "72")
  box(chip, "1,0.3765,0.5098", "1,0.6706,0.2941", "1.0", "10")
  txt(title, "Helvetica-Bold", "36", "42", "1,0.3765,0.5098", "46", "72", "72")
  same_tr(chip, title, 72, 8)
  return title
end

fn subhead(subtitle_text: String) -> Object
  let subtitle = tspan(sub_obj(subtitle_text), 110, 110, 150)
  txt(subtitle, "Helvetica-Bold", "22", "30", "0.1569,0.1333,0.2196", "22", "78", "78")
  subtitle.text_cjk_bold_passes = "3"
  subtitle.text_cjk_bold_dx = "0.04"
  return subtitle
end

fn text(text_value: String) -> Object
  return body_obj(text_value)
end

fn tex(text_value: String, scale: Number = 1) -> Object
  let obj = frame(text_value, "math", "math_tex", "108", "108", 14, 12, "1,0.9647,0.9294", "1,0.7373,0.3843", "1.4", "16")
  obj.render_kind = "vector_math"
  obj.text_parse = "none"
  obj.math_scale = str(scale)
  return obj
end

fn figure(text_value: String) -> Object
  return frame(text_value, "figure", "figure_text", "108", "108", 14, 12, "1,0.9647,0.9294", "1,0.7373,0.3843", "1.4", "16")
end

fn image(path_value: String, factor: Number = 1) -> Object
  let obj = img_obj(path_value)
  flow(obj, "108", "108")
  let chrome = panel(style("custom"))
  box(chrome, "1,0.9647,0.9294", "1,0.7373,0.3843", "1.4", "16")
  surround(chrome, obj, 14, 12)
  scale(obj, factor)
  require_asset_exists(obj)
  return obj
end

fn pdf(path_value: String, factor: Number = 1) -> Object
  let obj = pdf_obj(path_value)
  flow(obj, "108", "108")
  let chrome = panel(style("custom"))
  box(chrome, "1,0.9647,0.9294", "1,0.7373,0.3843", "1.4", "16")
  surround(chrome, obj, 14, 12)
  scale(obj, factor)
  require_asset_exists(obj)
  return obj
end

fn code(text_value: String, language_name: String = "python") -> Object
  return code_box(text_value, language_name, "108", "108", 18, 14, "1,0.9647,0.9294", "1,0.7373,0.3843", "1.4", "16")
end

fn note(text_value: String) -> Object
  return inset(note_obj(text_value), 124, 124)
end

fn toc(title_text: String) -> Object
  head(title_text)
  let list = toc_obj()
  let chrome = panel(style("pop"))
  box(chrome, "1,0.9647,0.9294", "1,0.7373,0.3843", "1.4", "16")
  surround(chrome, list, 14, 12)
  pageno()
  return list
end

fn cover(title_text: String, subtitle_text: String, author_name: String) -> Object
  let hero = style("pop_hero")
  let author_style = style("pop")
  let title = tl(styled(title_text, "title", hero), 72, 152)
  let subtitle = styled(subtitle_text, "subtitle", hero)
  let author = styled(author_name, "byline", author_style)
  txt(title, "Helvetica-Bold", "52", "60", "0.4745,0.3765,1", "26", "72", "72")
  txt(subtitle, "Helvetica", "22", "30", "0.1569,0.1333,0.2196", "22", "78", "78")
  txt(author, "Helvetica-Bold", "18", "24", "1,0.6706,0.2941", "18", "72", "72")

  below_l(subtitle, title, 6, 28)
  same_tr(author, title, 72, -4)
  return title
end
