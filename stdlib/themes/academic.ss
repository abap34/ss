import std:themes/default as *
import std:themes/default as base

fn default_theme() -> Theme
  return base::default_theme() with {
    body.text.size = 20
    body.text.line_height = 28
    body.text.color = c"0,0,0.0353"
    body.layout.spacing_after = 32
    body.layout.x = 96
    body.layout.right_inset = 96
    body.text.markdown_code_font_size = 18
    body.text.markdown_code_line_height = 24
    body.text.markdown_code_pad_x = 12
    body.text.markdown_code_pad_y = 10
    body.text.markdown_code_fill = c"0.94,0.94,0.94"
    body.text.markdown_code_stroke = c"0.78,0.78,0.78"
    body.text.markdown_code_line_width = 1
    body.text.markdown_code_radius = 0
    h1.text.size = 32
    h1.text.line_height = 36
    h1.text.color = c"0,0,0.0353"
    h1.text.font.weight = 400
    h1.layout.spacing_after = 48
    h1.layout.x = 96
    h1.layout.right_inset = 96
    h2.text.size = 28
    h2.text.line_height = 30
    h2.text.color = c"0,0,0.0353"
    h2.layout.spacing_after = 42
    h2.layout.x = 96
    h2.layout.right_inset = 96
    h3.text.size = 24
    h3.text.line_height = 28
    h3.text.color = c"0,0,0.0353"
    h3.layout.spacing_after = 36
    h3.layout.x = 96
    h3.layout.right_inset = 96
    head.text.size = 34
    head.text.line_height = 49.3
    head.text.color = c"0,0,0.0353"
    head.layout.spacing_after = 35
    head.layout.x = 72
    head.layout.right_inset = 72
    subhead.text.size = 12
    subhead.text.line_height = 24
    subhead.text.color = c"0,0,0.0353"
    subhead.layout.spacing_after = 34
    code.text.size = 15
    code.layout.x = 102
    code.layout.right_inset = 102
    code.chrome.fill = c"0.94,0.94,0.94"
    code.chrome.stroke = c"0.78,0.78,0.78"
    code.chrome.line_width = 1
    code.chrome.radius = 0
    code.chrome.pad_x = 12
    code.chrome.pad_y = 10
    cover.title.text.size = 44
    cover.title.text.line_height = 40
    cover.title.text.color = c"0,0,0.0353"
    cover.title.text.font.weight = 400
    cover.subtitle.text.size = 18
    cover.subtitle.text.line_height = 24
    cover.subtitle.text.color = c"0,0,0.0353"
    cover.subtitle.text.font.weight = 700
    cover.author.text.size = 20
    cover.author.text.line_height = 26
    cover.author.text.color = c"0,0,0.0353"
    cover.date.text.size = 14
    cover.date.text.line_height = 20
    cover.date.text.color = c"0,0,0.0353"
  }
end

fn theme!(theme_value: Theme) -> Void
  docctx().theme = theme_value
end

fn current_theme() -> Theme
  return docctx().theme ?? default_theme()
end

fn/! h1(text_value: String, theme: Theme = current_theme()) -> Object
  return base::h1(text_value, theme)
end

fn/! h2(text_value: String, theme: Theme = current_theme()) -> Object
  return base::h2(text_value, theme)
end

fn/! h3(text_value: String, theme: Theme = current_theme()) -> Object
  return base::h3(text_value, theme)
end

fn/! head(title_text: String, theme: Theme = current_theme()) -> Object
  let title = tl(title_obj(title_text), 30, 30)
  apply_text_block(title, theme.head)
  return title
end

fn/! subhead(subtitle_text: String, theme: Theme = current_theme()) -> Object
  let subtitle = tspan(sub_obj(subtitle_text), 96, 96, 150)
  apply_text_block(subtitle, theme.subhead)
  return subtitle
end

fn/! text(text_value: String, theme: Theme = current_theme()) -> Object
  return base::text(text_value, theme)
end

fn/! code(text_value: String, language_name: String = "python", theme: Theme = current_theme()) -> Object
  return base::code(text_value, language_name, theme)
end

fn/! code_file(path_value: String, language_name: String = "plain", theme: Theme = current_theme()) -> Object
  return code(readlines(path_value), language_name, theme)
end

fn toc(title_text: String, theme: Theme = current_theme()) -> Object
  let title = tl(lab_obj(title_text), 30, 30)
  apply_text_block(title, theme.toc.title)
  let list = toc_obj()
  apply_text_block(list, theme.toc.body)
  below(list, title, 35)
  return group(title, list)
end

fn toc!(title_text: String, theme: Theme = current_theme()) -> Object
  let contents = place!(toc(title_text, theme))
  pageno!()
  return contents
end

fn/! cover(title_text: String, subtitle_text: String, author_name: String, date: String = "", theme: Theme = current_theme()) -> Object
  let title = tl(title_obj(title_text), 72, 240)
  let subtitle = sub_obj(subtitle_text)
  let author = by_obj(author_name)
  let date_text = by_obj(date)
  apply_text_block(title, theme.cover.title)
  apply_text_block(subtitle, theme.cover.subtitle)
  apply_text_block(author, theme.cover.author)
  apply_text_block(date_text, theme.cover.date)

  below_l(subtitle, title, 0, 28)
  below_l(author, subtitle, 0, 36)
  below_l(date_text, author, 0, 18)
  return title
end
