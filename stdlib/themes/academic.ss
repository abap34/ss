import std:themes/default as base
import std:core/classes as classes
import std:core/components as components
import std:core/layout as layout
import std:core/objects as objects
import std:core/generated as generated

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
    callout.text_size = 20
    callout.text_line_height = 28
    callout.text_color = c"0,0,0.0353"
    callout.target_color = c"0,0,0.0353"
    callout.target_weight = 700
    callout.target_fill = none
    callout.target_border = none
    callout.target_border_width = 0
    callout.target_pad_x = 0
    callout.target_pad_y = 0
    callout.callout.stroke = c"0,0,0.0353"
    callout.callout.line_width = 1
    callout.callout.marker_size = 8
    callout.callout.border = c"0,0,0.0353"
    callout.callout.border_width = 0.8
    callout.callout.radius = 0
    callout.callout.text_size = 14
    callout.callout.text_line_height = 21
    callout.callout.text_color = c"0,0,0.0353"
  }
end

fn theme!(theme_value: Theme) -> Void
  docctx().theme = theme_value
end

fn current_theme() -> Theme
  return docctx().theme ?? default_theme()
end

fn annotate!(source_text: String, target_text: String, note_text: String, style: MarkedCalloutStyle = current_theme().callout) -> Object
  return components::marked_callout!(source_text, target_text, note_text, style)
end

fn annotate_down!(source_text: String, target_text: String, note_text: String, style: MarkedCalloutStyle = current_theme().callout) -> Object
  return components::marked_callout!(source_text, target_text, note_text, style with {
    rises = false
  })
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
  let title = objects::title_obj(title_text)
  title.text = theme.head.text
  title.layout = theme.head.layout
  title.underline = theme.head.underline
  ~ title.left == page.left + 30
  ~ title.top == page.top - 30
  return title
end

fn/! subhead(subtitle_text: String, theme: Theme = current_theme()) -> Object
  let subtitle = objects::sub_obj(subtitle_text)
  subtitle.text = theme.subhead.text
  subtitle.layout = theme.subhead.layout
  subtitle.underline = theme.subhead.underline
  ~ subtitle.left == page.left + 96
  ~ subtitle.right == page.right - 96
  ~ subtitle.top == page.top - 150
  return subtitle
end

fn/! text(text_value: String, theme: Theme = current_theme()) -> Object
  return base::text(text_value, theme)
end

fn/! note(text_value: String, theme: Theme = current_theme()) -> Object
  return base::note(text_value, theme)
end

fn/! tex(text_value: String, scale: Number = 1) -> Object
  return base::tex(text_value, scale)
end

fn/! figure(text_value: String, theme: Theme = current_theme()) -> Object
  return base::figure(text_value, theme)
end

fn/! image(path_value: String, factor: Number = 1, theme: Theme = current_theme()) -> Object
  return base::image(path_value, factor, theme)
end

fn/! pdf(path_value: String, factor: Number = 1, theme: Theme = current_theme()) -> Object
  return base::pdf(path_value, factor, theme)
end

fn/! code(text_value: String, language_name: String = "python", theme: Theme = current_theme()) -> Object
  return base::code(text_value, language_name, theme)
end

fn/! code_file(path_value: String, language_name: String = "plain", theme: Theme = current_theme()) -> Object
  return code(readlines(path_value), language_name, theme)
end

fn toc(title_text: String, theme: Theme = current_theme()) -> Object
  let title = objects::lab_obj(title_text)
  title.text = theme.toc.title.text
  title.layout = theme.toc.title.layout
  title.underline = theme.toc.title.underline
  let list = generated::toc_obj()
  list.text = theme.toc.body.text
  list.layout = theme.toc.body.layout
  list.underline = theme.toc.body.underline
  ~ title.left == page.left + 30
  ~ title.top == page.top - 30
  ~ list.top == title.bottom - 35
  return group(title, list)
end

fn toc!(title_text: String, theme: Theme = current_theme()) -> Object
  let contents = objects::place!(toc(title_text, theme))
  components::pageno!()
  return contents
end

fn/! cover(title_text: String, subtitle_text: String, author_name: String, date: String = "", theme: Theme = current_theme()) -> Object
  let title = objects::title_obj(title_text)
  let subtitle = objects::sub_obj(subtitle_text)
  let author = objects::by_obj(author_name)
  let date_text = objects::by_obj(date)
  title.text = theme.cover.title.text
  title.layout = theme.cover.title.layout
  title.underline = theme.cover.title.underline
  subtitle.text = theme.cover.subtitle.text
  subtitle.layout = theme.cover.subtitle.layout
  subtitle.underline = theme.cover.subtitle.underline
  author.text = theme.cover.author.text
  author.layout = theme.cover.author.layout
  author.underline = theme.cover.author.underline
  date_text.text = theme.cover.date.text
  date_text.layout = theme.cover.date.layout
  date_text.underline = theme.cover.date.underline

  ~ title.left == page.left + 72
  ~ title.top == page.top - 240
  ~ subtitle.left == title.left
  ~ subtitle.top == title.bottom - 28
  ~ author.left == subtitle.left
  ~ author.top == subtitle.bottom - 36
  ~ date_text.left == author.left
  ~ date_text.top == author.bottom - 18
  return group(title, subtitle, author, date_text)
end
