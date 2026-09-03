import std:themes/base as base
import std:core/classes as classes
import std:core/components as components
import std:core/layout as layout
import std:core/objects as objects
import std:core/render as render
import std:core/generated as generated

fn default_theme(options: ThemeOptions = ThemeOptions {}) -> Theme
  let highlight = render::code_theme_github_light()
  let base_text = TextStyle {
    font = FontFace { family = options.font_family ?? "Helvetica" }
    code_font = FontFace { family = options.code_font_family ?? "monospace" }
    color = options.text_color ?? c"0.08,0.08,0.08"
    link_color = options.accent_color ?? c"0.1,0.25,0.75"
    markdown_bold_color = options.accent_color
  }
  return Theme {
    body = TextBlockStyle {
      text = base_text with {
        parse = TextParseMode.block
        size = 24
        line_height = 31
        color = options.text_color ?? c"0.07,0.08,0.10"
        markdown_bold_color = options.accent_color ?? c"0.05,0.30,0.58"
        markdown_quote = MarkdownQuoteStyle {
          color = c"#374151"
          inset = 14
          pad_x = 18
          pad_y = 10
          fill = c"#f3f6fa"
          radius = 7
          bar_color = c"#4f7cac"
          bar_width = 4
        }
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
      text = base_text with {
        font.weight = 700
        size = 40
        line_height = 47
        color = options.text_color ?? c"0.04,0.06,0.09"
      }
      layout = LayoutStyle {
        spacing_after = 42
        x = 72
        right_inset = 72
      }
    }
    h2 = TextBlockStyle {
      text = base_text with {
        font.weight = 700
        size = 30
        line_height = 37
        color = options.text_color ?? c"0.07,0.09,0.13"
      }
      layout = LayoutStyle {
        spacing_after = 34
        x = 88
        right_inset = 88
      }
    }
    h3 = TextBlockStyle {
      text = base_text with {
        font.weight = 700
        size = 24
        line_height = 31
        color = options.text_color ?? c"0.10,0.12,0.16"
      }
      layout = LayoutStyle {
        spacing_after = 28
        x = 96
        right_inset = 96
      }
    }
    h4 = TextBlockStyle {
      text = base_text with {
        font.weight = 700
        size = 22
        line_height = 29
        color = options.text_color ?? c"0.12,0.14,0.18"
      }
      layout = LayoutStyle {
        spacing_after = 24
        x = 96
        right_inset = 96
      }
    }
    h5 = TextBlockStyle {
      text = base_text with {
        font.weight = 700
        size = 20
        line_height = 27
        color = options.text_color ?? c"0.14,0.16,0.20"
      }
      layout = LayoutStyle {
        spacing_after = 22
        x = 96
        right_inset = 96
      }
    }
    h6 = TextBlockStyle {
      text = base_text with {
        font.weight = 700
        size = 18
        line_height = 25
        color = options.text_color ?? c"0.16,0.18,0.22"
      }
      layout = LayoutStyle {
        spacing_after = 20
        x = 96
        right_inset = 96
      }
    }
    head = HeadStyle {
      title = TextBlockStyle {
        text = base_text with {
          font.weight = 700
          size = 36
          line_height = 44
          color = options.accent_color ?? c"0.04,0.06,0.09"
        }
        layout = LayoutStyle {
          spacing_after = 34
          x = 72
          right_inset = 72
        }
      }
      rule = RuleBlockStyle {
        rule = RuleStyle {
          stroke = options.accent_color ?? c"0.32,0.50,0.72"
          line_width = 2.0
        }
        layout = LayoutStyle {
          spacing_after = 48
        }
      }
      top = 56
      gap = 0
    }
    subhead = TextBlockStyle {
      text = base_text with {
        font.weight = 700
        size = 26
        line_height = 33
        color = options.text_color ?? c"0.08,0.10,0.14"
      }
      layout = LayoutStyle {
        spacing_after = 30
        x = 96
        right_inset = 96
      }
    }
    note = TextBlockStyle {
      text = base_text with {
        size = 15
        line_height = 20
        color = options.muted_color ?? c"0.38,0.42,0.48"
      }
      layout = LayoutStyle {
        spacing_after = 16
        x = 112
        right_inset = 112
      }
    }
    byline = TextBlockStyle {
      text = base_text with {
        size = 20
        line_height = 26
        color = options.muted_color ?? c"0.38,0.42,0.48"
      }
      layout = LayoutStyle {
        spacing_after = 18
        x = 72
        right_inset = 72
      }
    }
    label = TextBlockStyle {
      text = base_text with {
        font.weight = 700
        size = 14
        line_height = 18
        color = options.accent_color ?? c"0.2745,0.5098,0.7059"
      }
      layout = LayoutStyle {
        spacing_after = 0
        x = 72
        right_inset = 72
        wrap = WrapMode.off
      }
    }
    citation = TextBlockStyle {
      text = base_text with {
        parse = TextParseMode.inline
        size = 13
        line_height = 17
        color = options.muted_color ?? c"0.58,0.58,0.58"
        link_color = options.muted_color ?? options.accent_color ?? c"0.58,0.58,0.58"
      }
      layout = LayoutStyle {
        spacing_after = 0
        x = 120
        right_inset = 90
        wrap = WrapMode.off
      }
    }
    code = CodeBlockStyle {
      text = base_text with {
        parse = TextParseMode.none
        font = FontFace { family = options.code_font_family ?? "monospace" }
        size = 16
        line_height = none
        color = options.text_color ?? c"0.12,0.12,0.12"
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
      text = base_text with {
        parse = TextParseMode.block
        size = 24
        line_height = 31
        color = options.text_color ?? c"0.07,0.08,0.10"
        markdown_bold_color = options.accent_color ?? c"0.05,0.30,0.58"
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
        text = base_text with {
          font.weight = 700
          size = 36
          line_height = 44
          color = options.accent_color ?? c"0.04,0.06,0.09"
        }
        layout = LayoutStyle {
          spacing_after = 34
          x = 72
          right_inset = 72
        }
      }
      body = TextBlockStyle {
        text = base_text with {
          parse = TextParseMode.block
          size = 18
          line_height = 25
          color = options.text_color ?? c"0.07,0.08,0.10"
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
        text = base_text with {
          font.weight = 700
          size = 56
          line_height = 64
          color = options.accent_color ?? c"0.04,0.06,0.09"
        }
        layout = LayoutStyle {
          spacing_after = 26
          x = 72
          right_inset = 72
        }
      }
      subtitle = TextBlockStyle {
        text = base_text with {
          size = 30
          line_height = 38
          color = options.text_color ?? c"0.20,0.25,0.32"
        }
        layout = LayoutStyle {
          spacing_after = 24
          x = 72
          right_inset = 72
        }
      }
      author = TextBlockStyle {
        text = base_text with {
          size = 20
          line_height = 26
          color = options.accent_color ?? c"0.38,0.42,0.48"
        }
        layout = LayoutStyle {
          spacing_after = 18
          x = 72
          right_inset = 72
        }
      }
      accent = RuleBlockStyle {
        rule = RuleStyle {
          stroke = options.accent_color ?? c"0.32,0.50,0.72"
          line_width = 2.0
        }
      }
    }
    callout = MarkedCalloutStyle {
      text = base_text with {
        size = 24
        line_height = 31
        color = options.text_color ?? c"0.07,0.08,0.10"
      }
      target = base_text with {
        font.weight = 700
        size = 24
        line_height = 31
        color = options.accent_color ?? c"0.04,0.06,0.09"
      }
      target_chrome = ChromeStyle {
        fill = none
        stroke = none
        line_width = 0
        radius = 0
        pad_x = 0
        pad_y = 0
      }
      callout = CalloutStyle {
        stroke = options.accent_color ?? c"0.32,0.50,0.72"
        line_width = 1.6
        marker_size = 10
        text = base_text with {
          size = 17
          line_height = 25
          color = options.muted_color ?? c"0.30,0.34,0.40"
        }
        chrome = ChromeStyle {
          fill = none
          stroke = c"0.72,0.80,0.90"
          line_width = 1
          radius = 8
          pad_x = 18
          pad_y = 12
        }
      }
    }
    generated = GeneratedStyle {
      pageno = TextBlockStyle {
        text = base_text with {
          size = 13
          line_height = 16
          color = options.muted_color ?? c"0.5,0.5,0.5"
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
        text = base_text with {
          size = 12
          line_height = 15
          color = options.muted_color ?? c"0.42,0.42,0.42"
        }
        layout = LayoutStyle {
          spacing_after = 0
          x = 72
          right_inset = 160
          wrap = WrapMode.off
        }
      }
      watermark = TextBlockStyle {
        text = base_text with {
          size = 72
          line_height = 80
          color = options.muted_color ?? c"0.85,0.85,0.85"
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
  base::set_theme!(theme_value)
end

fn current_theme() -> Theme
  return docctx().theme ?? default_theme()
end

fn annotate!(source_text: String, target_text: String, note_text: String, style: MarkedCalloutStyle = current_theme().callout) -> Object
  return base::annotate_with_style!(source_text, target_text, note_text, style)
end

fn/! h1(title_text: String, theme: Theme = current_theme()) -> Object
  let title = objects::title_obj(title_text)
  return base::apply_text_block_style(title, theme.h1)
end

fn/! h2(subtitle_text: String, theme: Theme = current_theme()) -> Object
  let subtitle = objects::sub_obj(subtitle_text)
  return base::apply_text_block_style(subtitle, theme.h2)
end

fn/! h3(subtitle_text: String, theme: Theme = current_theme()) -> Object
  let subtitle = objects::sub_obj(subtitle_text)
  return base::apply_text_block_style(subtitle, theme.h3)
end

fn/! h4(subtitle_text: String, theme: Theme = current_theme()) -> Object
  let subtitle = objects::sub_obj(subtitle_text)
  return base::apply_text_block_style(subtitle, theme.h4)
end

fn/! h5(subtitle_text: String, theme: Theme = current_theme()) -> Object
  let subtitle = objects::sub_obj(subtitle_text)
  return base::apply_text_block_style(subtitle, theme.h5)
end

fn/! h6(subtitle_text: String, theme: Theme = current_theme()) -> Object
  let subtitle = objects::sub_obj(subtitle_text)
  return base::apply_text_block_style(subtitle, theme.h6)
end

fn/! head(title_text: String, theme: Theme = current_theme()) -> Object
  let rule = components::rule()
  let title = objects::title_obj(title_text)
  base::apply_text_block_style(title, theme.head.title)
  base::apply_rule_block_style(rule, theme.head.rule)
  ~ title.left == page.left + theme.head.title.layout.x
  ~ title.top == page.top - theme.head.top
  ~ rule.left == title.left
  ~ rule.right == page.right - theme.head.title.layout.right_inset
  ~ rule.top == title.bottom - theme.head.gap
  return group(title, rule)
end

fn/! subhead(subtitle_text: String, theme: Theme = current_theme()) -> Object
  let subtitle = objects::sub_obj(subtitle_text)
  base::apply_text_block_style(subtitle, theme.subhead)
  ~ subtitle.left == page.left + 96
  ~ subtitle.right == page.right - 96
  ~ subtitle.top == page.top - 124
  return subtitle
end

fn/! text(text_value: String, theme: Theme = current_theme()) -> Object
  let body = objects::body_obj(text_value)
  base::apply_markdown_text_style(body, theme)
  render::code_theme(body, theme.code.highlight)
  return body
end

fn/! note(text_value: String, theme: Theme = current_theme()) -> Object
  let note = objects::note_obj(text_value)
  return base::apply_text_block_style(note, theme.note)
end

fn/! byline(text_value: String, theme: Theme = current_theme()) -> Object
  return base::byline_with_style(text_value, theme.byline)
end

fn/! label(text_value: String, theme: Theme = current_theme()) -> Object
  return base::label_with_style(text_value, theme.label)
end

fn/! citation(target: Object, number: Number, reference_text: String, theme: Theme = current_theme()) -> Object
  return base::citation_with_style(target, number, reference_text, theme.citation)
end

fn/! pageno(theme: Theme = current_theme()) -> Object
  return base::pageno_with_style(theme.generated.pageno)
end

fn pagenos!(format: String? = none, theme: Theme = current_theme()) -> Void
  base::pagenos_with_style!(format, theme.generated.pageno)
end

fn footers!(text_value: String, theme: Theme = current_theme()) -> Void
  base::footers_with_style!(text_value, theme.generated.footer)
end

fn watermark!(text_value: String, theme: Theme = current_theme()) -> Void
  base::watermark_with_style!(text_value, theme.generated.watermark)
end

fn/! latex(text_value: String, scale: Number = 1) -> Object
  let obj = objects::latex_obj(text_value)
  obj.layout.x = 96
  obj.layout.right_inset = 96
  obj.layout.wrap = WrapMode.on
  obj.latex.scale = scale
  return obj
end

fn/! figure(text_value: String, theme: Theme = current_theme()) -> Object
  let obj = objects::raw_obj(text_value, "figure", "figure_text")
  base::apply_figure_block_style(obj, theme.figure)
  base::apply_markdown_heading_styles(obj, theme)
  render::code_theme(obj, theme.code.highlight)
  return obj
end

fn/! image(path_value: String, factor: Number = 1, theme: Theme = current_theme()) -> Object
  let obj = objects::img_obj(path_value)
  let image_style = theme.image with {
    asset.scale = factor
  }
  base::apply_asset_block_style(obj, image_style)
  require_asset_exists(obj)
  return obj
end

fn/! pdf(path_value: String, factor: Number = 1, page_number: Number = 1, page_box: PdfPageBox = PdfPageBox.crop, theme: Theme = current_theme()) -> Object
  let obj = objects::pdf_obj(path_value)
  let pdf_style = theme.pdf with {
    asset.scale = factor
    asset.pdf_page = page_number
    asset.pdf_box = page_box
  }
  base::apply_asset_block_style(obj, pdf_style)
  require_asset_exists(obj)
  return obj
end

fn/! code(text_value: String, language_name: String = "python", theme: Theme = current_theme()) -> Object
  let code = objects::code_obj(text_value)
  code.language = language_name
  base::apply_code_block_style(code, theme.code)
  render::code_theme(code, theme.code.highlight)
  return code
end

fn/! code_file(path_value: String, language_name: String = "plain", theme: Theme = current_theme()) -> Object
  return code(readlines(path_value), language_name, theme)
end

fn toc(title_text: String, theme: Theme = current_theme()) -> Object
  let title = objects::lab_obj(title_text)
  base::apply_text_block_style(title, theme.toc.title)
  let list = generated::toc_obj()
  base::apply_text_block_style(list, theme.toc.body)
  let chrome = components::panel()
  chrome.chrome = theme.toc.chrome
  ~ list.top == title.bottom - 34
  layout::surround(chrome, list, theme.toc.chrome.pad_x, theme.toc.chrome.pad_y)
  return group(title, chrome, list)
end

fn toc!(title_text: String, theme: Theme = current_theme()) -> Object
  let contents = objects::place!(toc(title_text, theme))
  pageno!(theme)
  return contents
end

fn/! cover(title_text: String, subtitle_text: String, author_name: String, theme: Theme = current_theme()) -> Object
  let title = objects::title_obj(title_text)
  let subtitle = objects::sub_obj(subtitle_text)
  let author = objects::by_obj(author_name)
  let accent = components::rule()
  base::apply_text_block_style(title, theme.cover.title)
  base::apply_text_block_style(subtitle, theme.cover.subtitle)
  base::apply_text_block_style(author, theme.cover.author)
  base::apply_rule_block_style(accent, theme.cover.accent)

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
