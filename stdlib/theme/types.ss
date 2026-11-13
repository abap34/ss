import std:text/style
import std:code/style
import std:assets/style
import std:components/toc/style

type ThemeOptions {
  font_family: String? = none
  code_font_family: String? = none
  text_color: Color? = none
  accent_color: Color? = none
  muted_color: Color? = none
}

const heading_default: TextBlockStyle = TextBlockStyle {} with { text.size = 36 }

type Theme {
  background_fill: Color? = none
  body: TextBlockStyle = default_text_style
  h1: TextBlockStyle = heading_default
  h2: TextBlockStyle = heading_default
  h3: TextBlockStyle = heading_default
  h4: TextBlockStyle = heading_default
  h5: TextBlockStyle = heading_default
  h6: TextBlockStyle = heading_default
  note: TextBlockStyle = TextBlockStyle {}
  byline: TextBlockStyle = TextBlockStyle {}
  label: TextBlockStyle = TextBlockStyle {}
  citation: TextBlockStyle = TextBlockStyle {}
  code: CodeBlockStyle = CodeBlockStyle {}
  image: AssetBlockStyle = AssetBlockStyle {}
  pdf: AssetBlockStyle = AssetBlockStyle {}
  page_number: TextBlockStyle = TextBlockStyle {}
  toc: TocStyle = TocStyle {}
}
