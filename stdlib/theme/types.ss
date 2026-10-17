import std:internal/classes
import std:text/style
import std:code/style
import std:assets/style
import std:components/figure/style
import std:components/toc/style
import std:templates/slide/style
import std:components/callout/style

type GeneratedStyle = record {
  pageno: TextBlockStyle = TextBlockStyle {}
  footer: TextBlockStyle = TextBlockStyle {}
  watermark: TextBlockStyle = TextBlockStyle {}
}

type ThemeOptions = record {
  font_family: String? = none
  code_font_family: String? = none
  text_color: Color? = none
  accent_color: Color? = none
  muted_color: Color? = none
}

type Theme = record {
  body: TextBlockStyle = TextBlockStyle {}
  h1: TextBlockStyle = TextBlockStyle {}
  h2: TextBlockStyle = TextBlockStyle {}
  h3: TextBlockStyle = TextBlockStyle {}
  h4: TextBlockStyle = TextBlockStyle {}
  h5: TextBlockStyle = TextBlockStyle {}
  h6: TextBlockStyle = TextBlockStyle {}
  head: HeadStyle = HeadStyle {}
  note: TextBlockStyle = TextBlockStyle {}
  byline: TextBlockStyle = TextBlockStyle {}
  label: TextBlockStyle = TextBlockStyle {}
  citation: TextBlockStyle = TextBlockStyle {}
  code: CodeBlockStyle = CodeBlockStyle {}
  figure: FigureBlockStyle = FigureBlockStyle {}
  image: AssetBlockStyle = AssetBlockStyle {}
  pdf: AssetBlockStyle = AssetBlockStyle {}
  toc: TocStyle = TocStyle {}
  generated: GeneratedStyle = GeneratedStyle {}
  callout: MarkedCalloutStyle = MarkedCalloutStyle {}
}
