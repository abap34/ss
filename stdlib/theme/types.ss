import std:internal/classes
import std:text/style
import std:code/style
import std:assets/style
import std:components/toc/style
import std:text/content as { Text }

type ThemeOptions {
  font_family: String? = none
  code_font_family: String? = none
  text_color: Color? = none
  accent_color: Color? = none
  muted_color: Color? = none
}

type Theme {
  body: TextBlockStyle = TextBlockStyle {}
  h1: TextBlockStyle = TextBlockStyle {}
  h2: TextBlockStyle = TextBlockStyle {}
  h3: TextBlockStyle = TextBlockStyle {}
  h4: TextBlockStyle = TextBlockStyle {}
  h5: TextBlockStyle = TextBlockStyle {}
  h6: TextBlockStyle = TextBlockStyle {}
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
