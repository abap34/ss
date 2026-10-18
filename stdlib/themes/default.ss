import std:theme/types as { Theme, ThemeOptions }
import std:text/style as { TextBlockStyle }
import std:text/types as { TextStyle, FontFace, TextParseMode, MarkdownHeadingStyle, MarkdownHeadingStyles, MarkdownQuoteStyle }
import std:layout/types as { LayoutStyle, WrapMode, FitPolicy }
import std:code/style as { CodeBlockStyle }
import std:assets/style as { AssetBlockStyle }
import std:assets/types as { AssetStyle }
import std:graphics/paint/types as { ChromeStyle }
import std:components/toc/style as { TocStyle }
import std:code/palettes as palette

fn default_theme(options: ThemeOptions = ThemeOptions {}) -> Theme
  let highlight = palette::code_theme_github_light()
  let base_text = TextStyle {} with {
    font = FontFace { family = options.font_family ?? "Helvetica" }
    code_font = FontFace { family = options.code_font_family ?? "monospace" }
    color = options.text_color ?? c"0.08,0.08,0.08"
    link_color = options.accent_color ?? c"0.1,0.25,0.75"
    markdown.bold_color = options.accent_color
    math.scale = 1.05
  }
  let heading = TextBlockStyle {
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
  let theme = Theme {
    body = TextBlockStyle {
      text = base_text with {
        parse = TextParseMode.block
        size = 24
        line_height = 31
        color = options.text_color ?? c"0.07,0.08,0.10"
        markdown.bold_color = options.accent_color ?? c"0.05,0.30,0.58"
        markdown.quote = MarkdownQuoteStyle {
          color = c"#374151"
          inset = 14
          pad_x = 18
          pad_y = 10
          fill = c"#f3f6fa"
          radius = 7
          bar_color = c"#4f7cac"
          bar_width = 4
        }
        markdown.code.size = 19
        markdown.code.line_height = 25
        markdown.code.chrome.pad_x = 12
        markdown.code.chrome.pad_y = 9
        markdown.code.chrome.fill = highlight.fill ?? c"#f6f8fa"
        markdown.code.chrome.stroke = highlight.stroke ?? c"#d0d7de"
        markdown.code.chrome.line_width = 0.9
        markdown.code.chrome.radius = 6
        markdown.table.cell_pad_x = 12
        markdown.table.cell_pad_y = 9
        markdown.table.border = c"0.76,0.82,0.90"
        markdown.table.line_width = 0.8
        markdown.table.header_fill = c"0.90,0.94,0.98"
        markdown.table.alt_row_fill = c"0.985,0.990,0.996"
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
      title = heading
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
    }
    page_number = TextBlockStyle {
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
  }
  return theme with {
    body.headings = MarkdownHeadingStyles {
      h1 = MarkdownHeadingStyle { text = theme.h1.text }
      h2 = MarkdownHeadingStyle { text = theme.h2.text }
      h3 = MarkdownHeadingStyle { text = theme.h3.text }
      h4 = MarkdownHeadingStyle { text = theme.h4.text }
      h5 = MarkdownHeadingStyle { text = theme.h5.text }
      h6 = MarkdownHeadingStyle { text = theme.h6.text }
    }
  }
end
