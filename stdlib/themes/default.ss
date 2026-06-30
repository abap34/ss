import std:themes/base as base
import std:core/classes as classes
import std:core/components as components
import std:core/layout as layout
import std:core/objects as objects
import std:core/render as render
import std:core/generated as generated

fn default_theme() -> Theme
  let highlight = render::code_theme_github_light()
  return Theme {
    body = TextBlockStyle {
      text = TextStyle {
        parse = TextParseMode.block
        font = FontFace { family = "Helvetica" }
        code_font = FontFace { family = "Courier" }
        size = 24
        line_height = 31
        color = c"0.07,0.08,0.10"
        markdown_bold_color = c"0.05,0.30,0.58"
        markdown_code_font_size = 19
        markdown_code_line_height = 25
        markdown_code_pad_x = 12
        markdown_code_pad_y = 9
        markdown_code_fill = highlight.fill ?? c"#f6f8fa"
        markdown_code_stroke = highlight.stroke ?? c"#d0d7de"
        markdown_code_line_width = 0.9
        markdown_code_radius = 6
        markdown_table_cell_pad_x = 12
        markdown_table_cell_pad_y = 9
        markdown_table_border = c"0.76,0.82,0.90"
        markdown_table_line_width = 0.8
        markdown_table_header_fill = c"0.90,0.94,0.98"
        markdown_table_alt_row_fill = c"0.985,0.990,0.996"
      }
      layout = LayoutStyle {
        spacing_after = 28
        x = 96
        right_inset = 96
      }
    }
    h1 = TextBlockStyle {
      text = TextStyle {
        font = FontFace { family = "Helvetica", weight = 700 }
        size = 40
        line_height = 47
        color = c"0.04,0.06,0.09"
      }
      layout = LayoutStyle {
        spacing_after = 42
        x = 72
        right_inset = 72
      }
    }
    h2 = TextBlockStyle {
      text = TextStyle {
        font = FontFace { family = "Helvetica", weight = 700 }
        size = 30
        line_height = 37
        color = c"0.07,0.09,0.13"
      }
      layout = LayoutStyle {
        spacing_after = 34
        x = 88
        right_inset = 88
      }
    }
    h3 = TextBlockStyle {
      text = TextStyle {
        font = FontFace { family = "Helvetica", weight = 700 }
        size = 24
        line_height = 31
        color = c"0.10,0.12,0.16"
      }
      layout = LayoutStyle {
        spacing_after = 28
        x = 96
        right_inset = 96
      }
    }
    head = TextBlockStyle {
      text = TextStyle {
        font = FontFace { family = "Helvetica", weight = 700 }
        size = 36
        line_height = 44
        color = c"0.04,0.06,0.09"
      }
      layout = LayoutStyle {
        spacing_after = 34
        x = 72
        right_inset = 72
      }
    }
    subhead = TextBlockStyle {
      text = TextStyle {
        font = FontFace { family = "Helvetica", weight = 700 }
        size = 26
        line_height = 33
        color = c"0.08,0.10,0.14"
        cjk_bold_passes = 3
        cjk_bold_dx = 0.04
      }
      layout = LayoutStyle {
        spacing_after = 30
        x = 96
        right_inset = 96
      }
    }
    note = TextBlockStyle {
      text = TextStyle {
        font = FontFace { family = "Helvetica" }
        size = 15
        line_height = 20
        color = c"0.38,0.42,0.48"
      }
      layout = LayoutStyle {
        spacing_after = 16
        x = 112
        right_inset = 112
      }
    }
    byline = TextBlockStyle {
      text = TextStyle {
        font = FontFace { family = "Helvetica" }
        size = 20
        line_height = 26
        color = c"0.38,0.42,0.48"
      }
      layout = LayoutStyle {
        spacing_after = 18
        x = 72
        right_inset = 72
      }
    }
    label = TextBlockStyle {
      text = TextStyle {
        font = FontFace { family = "Helvetica", weight = 700 }
        size = 14
        line_height = 18
        color = c"0.2745,0.5098,0.7059"
      }
      layout = LayoutStyle {
        spacing_after = 0
        x = 72
        right_inset = 72
        wrap = WrapMode.off
      }
    }
    citation = TextBlockStyle {
      text = TextStyle {
        parse = TextParseMode.inline
        font = FontFace { family = "Helvetica" }
        size = 13
        line_height = 17
        color = c"0.58,0.58,0.58"
        link_color = c"0.58,0.58,0.58"
      }
      layout = LayoutStyle {
        spacing_after = 0
        x = 120
        right_inset = 90
        wrap = WrapMode.off
      }
    }
    code = CodeBlockStyle {
      text = TextStyle {
        parse = TextParseMode.none
        font = FontFace { family = "Menlo" }
        code_font = FontFace { family = "Menlo" }
        size = 16
        line_height = none
        color = c"0.12,0.12,0.12"
      }
      layout = LayoutStyle {
        spacing_after = 30
        x = 96
        right_inset = 96
        wrap = WrapMode.off
      }
      highlight = highlight
      chrome = ChromeStyle {
        fill = highlight.fill ?? c"#f6f8fa"
        stroke = highlight.stroke ?? c"#d0d7de"
        line_width = 0.9
        radius = 8
        pad_x = 16
        pad_y = 12
      }
    }
    figure = FigureBlockStyle {
      text = TextStyle {
        parse = TextParseMode.block
        font = FontFace { family = "Helvetica" }
        size = 24
        line_height = 31
        color = c"0.07,0.08,0.10"
        markdown_bold_color = c"0.05,0.30,0.58"
      }
      layout = LayoutStyle {
        spacing_after = 34
        x = 102
        right_inset = 102
      }
      chrome = ChromeStyle {
        fill = c"0.997,0.999,1.000"
        stroke = c"0.78,0.84,0.92"
        line_width = 0.9
        radius = 8
        pad_x = 16
        pad_y = 12
      }
    }
    image = AssetBlockStyle {
      layout = LayoutStyle {
        spacing_after = 30
        x = 102
        right_inset = 102
      }
      asset = AssetStyle { scale = 1 }
    }
    pdf = AssetBlockStyle {
      layout = LayoutStyle {
        spacing_after = 30
        x = 102
        right_inset = 102
      }
      asset = AssetStyle { scale = 1 }
      chrome = ChromeStyle {
        fill = c"1,1,1"
        stroke = c"0.78,0.84,0.92"
        line_width = 0.9
        radius = 8
        pad_x = 12
        pad_y = 10
      }
    }
    toc = TocStyle {
      title = TextBlockStyle {
        text = TextStyle {
          font = FontFace { family = "Helvetica", weight = 700 }
          size = 36
          line_height = 44
          color = c"0.04,0.06,0.09"
        }
        layout = LayoutStyle {
          spacing_after = 34
          x = 72
          right_inset = 72
        }
      }
      body = TextBlockStyle {
        text = TextStyle {
          parse = TextParseMode.block
          font = FontFace { family = "Helvetica" }
          size = 18
          line_height = 25
          color = c"0.07,0.08,0.10"
        }
        layout = LayoutStyle {
          spacing_after = 28
          x = 96
          right_inset = 96
        }
      }
      chrome = ChromeStyle {
        fill = c"1,1,1"
        stroke = c"0.78,0.84,0.92"
        line_width = 0.9
        radius = 8
        pad_x = 14
        pad_y = 12
      }
    }
    cover = CoverStyle {
      title = TextBlockStyle {
        text = TextStyle {
          font = FontFace { family = "Helvetica", weight = 700 }
          size = 56
          line_height = 64
          color = c"0.04,0.06,0.09"
        }
        layout = LayoutStyle {
          spacing_after = 26
          x = 72
          right_inset = 72
        }
      }
      subtitle = TextBlockStyle {
        text = TextStyle {
          font = FontFace { family = "Helvetica" }
          size = 30
          line_height = 38
          color = c"0.20,0.25,0.32"
        }
        layout = LayoutStyle {
          spacing_after = 24
          x = 72
          right_inset = 72
        }
      }
      author = TextBlockStyle {
        text = TextStyle {
          font = FontFace { family = "Helvetica" }
          size = 20
          line_height = 26
          color = c"0.38,0.42,0.48"
        }
        layout = LayoutStyle {
          spacing_after = 18
          x = 72
          right_inset = 72
        }
      }
      accent = RuleBlockStyle {
        rule = RuleStyle {
          stroke = c"0.32,0.50,0.72"
          line_width = 2.0
        }
      }
    }
    callout = MarkedCalloutStyle {
      text_size = 24
      text_line_height = 31
      text_color = c"0.07,0.08,0.10"
      target_color = c"0.04,0.06,0.09"
      target_weight = 700
      target_fill = none
      target_border = none
      target_border_width = 0
      target_pad_x = 0
      target_pad_y = 0
      callout = CalloutStyle {
        stroke = c"0.32,0.50,0.72"
        line_width = 1.6
        marker_size = 10
        border = c"0.72,0.80,0.90"
        border_width = 1
        radius = 8
        text_size = 17
        text_line_height = 25
        text_color = c"0.30,0.34,0.40"
      }
    }
    generated = GeneratedStyle {
      pageno = TextBlockStyle {
        text = TextStyle {
          font = FontFace { family = "Helvetica" }
          size = 13
          line_height = 16
          color = c"0.5,0.5,0.5"
        }
        layout = LayoutStyle {
          spacing_after = 0
          x = 60
          right_inset = 24
          wrap = WrapMode.off
          fit = FitPolicy.error
        }
      }
      footer = TextBlockStyle {
        text = TextStyle {
          font = FontFace { family = "Helvetica" }
          size = 12
          line_height = 15
          color = c"0.42,0.42,0.42"
        }
        layout = LayoutStyle {
          spacing_after = 0
          x = 72
          right_inset = 160
          wrap = WrapMode.off
        }
      }
      watermark = TextBlockStyle {
        text = TextStyle {
          font = FontFace { family = "Helvetica" }
          size = 72
          line_height = 80
          color = c"0.85,0.85,0.85"
        }
        layout = LayoutStyle {
          spacing_after = 0
          x = 0
          right_inset = 0
          wrap = WrapMode.off
        }
      }
    }
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

fn/! h1(title_text: String, theme: Theme = current_theme()) -> Object
  let title = objects::title_obj(title_text)
  title.text = theme.h1.text
  title.layout = theme.h1.layout
  title.underline = theme.h1.underline
  return title
end

fn/! h2(subtitle_text: String, theme: Theme = current_theme()) -> Object
  let subtitle = objects::sub_obj(subtitle_text)
  subtitle.text = theme.h2.text
  subtitle.layout = theme.h2.layout
  subtitle.underline = theme.h2.underline
  return subtitle
end

fn/! h3(subtitle_text: String, theme: Theme = current_theme()) -> Object
  let subtitle = objects::sub_obj(subtitle_text)
  subtitle.text = theme.h3.text
  subtitle.layout = theme.h3.layout
  subtitle.underline = theme.h3.underline
  return subtitle
end

fn/! head(title_text: String, theme: Theme = current_theme()) -> Object
  let rule = components::rule()
  let title = objects::title_obj(title_text)
  title.text = theme.head.text
  title.layout = theme.head.layout
  title.underline = theme.head.underline
  rule.rule = theme.cover.accent.rule
  rule.layout_spacing_after = 48
  ~ title.left == page.left + 72
  ~ title.top == page.top - 56
  ~ rule.left == page.left + 72
  ~ rule.right == page.right - 72
  ~ rule.top == title.bottom + 4
  return group(title, rule)
end

fn/! subhead(subtitle_text: String, theme: Theme = current_theme()) -> Object
  let subtitle = objects::sub_obj(subtitle_text)
  subtitle.text = theme.subhead.text
  subtitle.layout = theme.subhead.layout
  subtitle.underline = theme.subhead.underline
  ~ subtitle.left == page.left + 96
  ~ subtitle.right == page.right - 96
  ~ subtitle.top == page.top - 124
  return subtitle
end

fn/! text(text_value: String, theme: Theme = current_theme()) -> Object
  let body = objects::body_obj(text_value)
  body.text = theme.body.text
  body.layout = theme.body.layout
  body.underline = theme.body.underline
  render::code_theme(body, theme.code.highlight)
  return body
end

fn/! note(text_value: String, theme: Theme = current_theme()) -> Object
  let note = objects::note_obj(text_value)
  note.text = theme.note.text
  note.layout = theme.note.layout
  note.underline = theme.note.underline
  return note
end

fn/! tex(text_value: String, scale: Number = 1) -> Object
  let obj = objects::tex_obj(text_value)
  obj.layout_x = 96
  obj.layout_right_inset = 96
  obj.wrap = WrapMode.on
  obj.math_scale = scale
  return obj
end

fn/! figure(text_value: String, theme: Theme = current_theme()) -> Object
  let obj = objects::raw_obj(text_value, "figure", "figure_text")
  obj.text = theme.figure.text
  obj.layout = theme.figure.layout
  render::code_theme(obj, theme.code.highlight)
  let chrome = components::panel()
  chrome.chrome = theme.figure.chrome
  chrome.layout_spacing_after = theme.figure.layout.spacing_after
  layout::surround(chrome, obj, theme.figure.chrome.pad_x, theme.figure.chrome.pad_y)
  return obj
end

fn/! image(path_value: String, factor: Number = 1, theme: Theme = current_theme()) -> Object
  let obj = objects::img_obj(path_value)
  let image_style = theme.image with {
    asset.scale = factor
  }
  obj.layout = image_style.layout
  obj.asset = image_style.asset
  require_asset_exists(obj)
  return obj
end

fn/! pdf(path_value: String, factor: Number = 1, theme: Theme = current_theme()) -> Object
  let obj = objects::pdf_obj(path_value)
  let pdf_style = theme.pdf with {
    asset.scale = factor
  }
  obj.layout = pdf_style.layout
  obj.asset = pdf_style.asset
  let chrome = components::panel()
  chrome.chrome = theme.pdf.chrome
  chrome.layout_spacing_after = theme.pdf.layout.spacing_after
  layout::surround(chrome, obj, theme.pdf.chrome.pad_x, theme.pdf.chrome.pad_y)
  require_asset_exists(obj)
  return obj
end

fn/! code(text_value: String, language_name: String = "python", theme: Theme = current_theme()) -> Object
  let code = objects::code_obj(text_value)
  code.language = language_name
  code.text = theme.code.text
  code.layout = theme.code.layout
  render::code_theme(code, theme.code.highlight)
  let chrome = components::panel()
  chrome.chrome = theme.code.chrome
  chrome.layout_spacing_after = theme.code.layout.spacing_after
  layout::surround(chrome, code, theme.code.chrome.pad_x, theme.code.chrome.pad_y)
  return code
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
  let chrome = components::panel()
  chrome.chrome = theme.toc.chrome
  ~ list.top == title.bottom - 34
  layout::surround(chrome, list, theme.toc.chrome.pad_x, theme.toc.chrome.pad_y)
  return group(title, chrome, list)
end

fn toc!(title_text: String, theme: Theme = current_theme()) -> Object
  let contents = objects::place!(toc(title_text, theme))
  components::pageno!()
  return contents
end

fn/! cover(title_text: String, subtitle_text: String, author_name: String, theme: Theme = current_theme()) -> Object
  let title = objects::title_obj(title_text)
  let subtitle = objects::sub_obj(subtitle_text)
  let author = objects::by_obj(author_name)
  let accent = components::rule()
  title.text = theme.cover.title.text
  title.layout = theme.cover.title.layout
  title.underline = theme.cover.title.underline
  subtitle.text = theme.cover.subtitle.text
  subtitle.layout = theme.cover.subtitle.layout
  subtitle.underline = theme.cover.subtitle.underline
  author.text = theme.cover.author.text
  author.layout = theme.cover.author.layout
  author.underline = theme.cover.author.underline
  accent.rule = theme.cover.accent.rule

  ~ title.left == page.left + 72
  ~ title.top == page.top - 148
  ~ subtitle.left == title.left
  ~ subtitle.top == title.bottom - 28
  ~ author.left == subtitle.left
  ~ author.top == subtitle.bottom - 40
  ~ accent.left == page.left + 72
  ~ accent.right == accent.left + 160
  ~ accent.top == author.bottom - 32
  return group(title, subtitle, author, accent)
end
