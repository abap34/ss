import std:themes/default as base
import std:themes/base as theme_base
import std:core/classes as classes
import std:core/components as components
import std:core/layout as layout
import std:core/objects as objects
import std:core/generated as generated

fn default_theme() -> Theme
  return base::default_theme() with {
    body.text.size = 20
    body.text.line_height = 28
    body.text.color = c"0.1569,0.1333,0.2196"
    body.text.markdown_code_font_size = 18
    body.text.markdown_code_line_height = 24
    body.text.markdown_code_pad_x = 14
    body.text.markdown_code_pad_y = 12
    body.text.markdown_code_fill = c"1,0.9647,0.9294"
    body.text.markdown_code_stroke = c"1,0.7373,0.3843"
    body.text.markdown_code_line_width = 1.4
    body.text.markdown_code_radius = 16
    h1.text.size = 36
    h1.text.line_height = 42
    h1.text.color = c"1,0.3765,0.5098"
    h1.layout.spacing_after = 46
    h1.layout.x = 72
    h1.layout.right_inset = 72
    h2.text.size = 22
    h2.text.line_height = 30
    h2.text.color = c"0.1569,0.1333,0.2196"
    h2.text.font.weight = 400
    h2.layout.spacing_after = 22
    h2.layout.x = 78
    h2.layout.right_inset = 78
    head.text.size = 36
    head.text.line_height = 42
    head.text.color = c"1,0.3765,0.5098"
    head.layout.spacing_after = 46
    subhead.text.size = 22
    subhead.text.line_height = 30
    subhead.text.color = c"0.1569,0.1333,0.2196"
    subhead.text.font.weight = 700
    subhead.layout.spacing_after = 22
    note.layout.x = 124
    note.layout.right_inset = 124
    code.layout.x = 108
    code.layout.right_inset = 108
    code.chrome.fill = c"1,0.9647,0.9294"
    code.chrome.stroke = c"1,0.7373,0.3843"
    code.chrome.line_width = 1.4
    code.chrome.radius = 16
    code.chrome.pad_x = 18
    code.chrome.pad_y = 14
    figure.layout.x = 108
    figure.layout.right_inset = 108
    figure.chrome.fill = c"1,0.9647,0.9294"
    figure.chrome.stroke = c"1,0.7373,0.3843"
    figure.chrome.line_width = 1.4
    figure.chrome.radius = 16
    figure.chrome.pad_x = 14
    figure.chrome.pad_y = 12
    image.layout.x = 108
    image.layout.right_inset = 108
    image.chrome.fill = c"1,0.9647,0.9294"
    image.chrome.stroke = c"1,0.7373,0.3843"
    image.chrome.line_width = 1.4
    image.chrome.radius = 16
    image.chrome.pad_x = 14
    image.chrome.pad_y = 12
    pdf.layout.x = 108
    pdf.layout.right_inset = 108
    pdf.chrome.fill = c"1,0.9647,0.9294"
    pdf.chrome.stroke = c"1,0.7373,0.3843"
    pdf.chrome.line_width = 1.4
    pdf.chrome.radius = 16
    pdf.chrome.pad_x = 14
    pdf.chrome.pad_y = 12
    toc.title.text.size = 36
    toc.title.text.line_height = 42
    toc.title.text.color = c"1,0.3765,0.5098"
    toc.title.layout.spacing_after = 46
    toc.chrome.fill = c"1,0.9647,0.9294"
    toc.chrome.stroke = c"1,0.7373,0.3843"
    toc.chrome.line_width = 1.4
    toc.chrome.radius = 16
    toc.chrome.pad_x = 14
    toc.chrome.pad_y = 12
    cover.title.text.size = 52
    cover.title.text.line_height = 60
    cover.title.text.color = c"0.4745,0.3765,1"
    cover.title.text.font.weight = 700
    cover.subtitle.text.size = 22
    cover.subtitle.text.line_height = 30
    cover.subtitle.text.color = c"0.1569,0.1333,0.2196"
    cover.subtitle.text.font.weight = 400
    cover.author.text.size = 18
    cover.author.text.line_height = 24
    cover.author.text.color = c"1,0.6706,0.2941"
    cover.author.text.font.weight = 700
    callout.text_size = 20
    callout.text_line_height = 28
    callout.text_color = c"0.1569,0.1333,0.2196"
    callout.target_color = c"0.4745,0.3765,1"
    callout.target_weight = 700
    callout.target_fill = c"1,0.9647,0.9294"
    callout.target_border = c"1,0.7373,0.3843"
    callout.target_border_width = 1.4
    callout.target_radius = 12
    callout.target_pad_x = 8
    callout.target_pad_y = 4
    callout.callout.stroke = c"1,0.3765,0.5098"
    callout.callout.line_width = 2.4
    callout.callout.marker_size = 14
    callout.callout.fill = c"1,0.9647,0.9294"
    callout.callout.border = c"1,0.7373,0.3843"
    callout.callout.border_width = 1.4
    callout.callout.radius = 14
    callout.callout.text_size = 18
    callout.callout.text_line_height = 27
    callout.callout.text_color = c"0.1569,0.1333,0.2196"
  }
end

fn theme!(theme_value: Theme) -> Void
  theme_base::set_theme!(theme_value)
end

fn current_theme() -> Theme
  return theme_base::current_theme_or(default_theme())
end

fn annotate!(source_text: String, target_text: String, note_text: String, style: MarkedCalloutStyle = current_theme().callout) -> Object
  return theme_base::annotate_with_style!(source_text, target_text, note_text, style)
end

fn annotate_down!(source_text: String, target_text: String, note_text: String, style: MarkedCalloutStyle = current_theme().callout) -> Object
  return theme_base::annotate_down_with_style!(source_text, target_text, note_text, style)
end

fn/! h1(title_text: String, theme: Theme = current_theme()) -> Object
  return base::h1(title_text, theme)
end

fn/! h2(subtitle_text: String, theme: Theme = current_theme()) -> Object
  return base::h2(subtitle_text, theme)
end

fn/! h3(subtitle_text: String, theme: Theme = current_theme()) -> Object
  return base::h3(subtitle_text, theme)
end

fn/! h4(subtitle_text: String, theme: Theme = current_theme()) -> Object
  return base::h4(subtitle_text, theme)
end

fn/! h5(subtitle_text: String, theme: Theme = current_theme()) -> Object
  return base::h5(subtitle_text, theme)
end

fn/! h6(subtitle_text: String, theme: Theme = current_theme()) -> Object
  return base::h6(subtitle_text, theme)
end

fn/! head(title_text: String, theme: Theme = current_theme()) -> Object
  let chip = objects::txt_obj(title_text, "label")
  let chip_bg = components::panel()
  let title = objects::txt_obj(title_text, "title")
  theme_base::apply_text_block_style(chip, theme.label)
  chip_bg.chrome = ChromeStyle {
    fill = c"1,0.3765,0.5098"
    stroke = c"1,0.6706,0.2941"
    line_width = 1
    radius = 10
  }
  theme_base::apply_text_block_style(title, theme.head)
  ~ title.left == page.left + 72
  ~ title.top == page.top - 98
  ~ chip.right == page.right - 72
  ~ chip.top == title.top + 8
  layout::surround(chip_bg, chip, 12, 6)
  return group(title, chip_bg, chip)
end

fn/! subhead(subtitle_text: String, theme: Theme = current_theme()) -> Object
  let subtitle = objects::sub_obj(subtitle_text)
  theme_base::apply_text_block_style(subtitle, theme.subhead)
  ~ subtitle.left == page.left + 110
  ~ subtitle.right == page.right - 110
  ~ subtitle.top == page.top - 150
  return subtitle
end

fn/! text(text_value: String, theme: Theme = current_theme()) -> Object
  return base::text(text_value, theme)
end

fn/! tex(text_value: String, scale: Number = 1) -> Object
  let obj = objects::tex_obj(text_value)
  obj.layout.x = 108
  obj.layout.right_inset = 108
  obj.layout.wrap = WrapMode.on
  obj.math.scale = scale
  return obj
end

fn/! figure(text_value: String, theme: Theme = current_theme()) -> Object
  return base::figure(text_value, theme)
end

fn/! image(path_value: String, factor: Number = 1, theme: Theme = current_theme()) -> Object
  return base::image(path_value, factor, theme)
end

fn/! pdf(path_value: String, factor: Number = 1, page_number: Number = 1, page_box: PdfPageBox = PdfPageBox.crop, theme: Theme = current_theme()) -> Object
  return base::pdf(path_value, factor, page_number, page_box, theme)
end

fn/! code(text_value: String, language_name: String = "python", theme: Theme = current_theme()) -> Object
  return base::code(text_value, language_name, theme)
end

fn/! code_file(path_value: String, language_name: String = "plain", theme: Theme = current_theme()) -> Object
  return code(readlines(path_value), language_name, theme)
end

fn/! note(text_value: String, theme: Theme = current_theme()) -> Object
  let note = objects::note_obj(text_value)
  return theme_base::apply_text_block_style(note, theme.note)
end

fn/! byline(text_value: String, theme: Theme = current_theme()) -> Object
  return theme_base::byline_with_style(text_value, theme.byline)
end

fn/! label(text_value: String, theme: Theme = current_theme()) -> Object
  return theme_base::label_with_style(text_value, theme.label)
end

fn/! citation(target: Object, number: Number, reference_text: String, theme: Theme = current_theme()) -> Object
  return theme_base::citation_with_style(target, number, reference_text, theme.citation)
end

fn/! pageno(theme: Theme = current_theme()) -> Object
  return theme_base::pageno_with_style(theme.generated.pageno)
end

fn pagenos!(format: String? = none, theme: Theme = current_theme()) -> Void
  theme_base::pagenos_with_style!(format, theme.generated.pageno)
end

fn footers!(text_value: String, theme: Theme = current_theme()) -> Void
  theme_base::footers_with_style!(text_value, theme.generated.footer)
end

fn watermark!(text_value: String, theme: Theme = current_theme()) -> Void
  theme_base::watermark_with_style!(text_value, theme.generated.watermark)
end

fn toc(title_text: String, theme: Theme = current_theme()) -> Object
  let title = objects::txt_obj(title_text, "label")
  theme_base::apply_text_block_style(title, theme.toc.title)
  let list = generated::toc_obj()
  theme_base::apply_text_block_style(list, theme.toc.body)
  let chrome = components::panel()
  chrome.chrome = theme.toc.chrome
  ~ title.left == page.left + 72
  ~ title.top == page.top - 98
  ~ list.top == title.bottom - 46
  layout::surround(chrome, list, theme.toc.chrome.pad_x, theme.toc.chrome.pad_y)
  return group(title, chrome, list)
end

fn toc!(title_text: String, theme: Theme = current_theme()) -> Object
  let contents = objects::place!(toc(title_text, theme))
  pageno!(theme)
  return contents
end

fn/! cover(title_text: String, subtitle_text: String, author_name: String, theme: Theme = current_theme()) -> Object
  let title = objects::txt_obj(title_text, "title")
  let subtitle = objects::txt_obj(subtitle_text, "subtitle")
  let author = objects::txt_obj(author_name, "byline")
  theme_base::apply_text_block_style(title, theme.cover.title)
  theme_base::apply_text_block_style(subtitle, theme.cover.subtitle)
  theme_base::apply_text_block_style(author, theme.cover.author)

  ~ title.left == page.left + 72
  ~ title.top == page.top - 152
  ~ subtitle.left == title.left + 6
  ~ subtitle.top == title.bottom - 28
  ~ author.right == page.right - 72
  ~ author.top == title.top - 4
  return group(title, subtitle, author)
end
