import std:code/types
import std:graphics/paint/types
import std:layout/types
import std:math/types

type SemanticRole = auto | paragraph | heading | code | figure | caption

type SemanticStyle = record {
  role: SemanticRole = SemanticRole.auto
  heading_level: Number? = none
}

type RenderKind = text | code | latex | vector_asset | raster_asset | vector_path | connector | chrome_only

type TextParseMode = none | plain | inline | block

type FontStyle = normal | oblique | italic

type FontStretch = ultra_condensed | extra_condensed | condensed | semi_condensed | normal | semi_expanded | expanded | extra_expanded | ultra_expanded

type FontFace = record {
  family: String = "Helvetica"
  weight: Number = 400
  style: FontStyle = FontStyle.normal
  stretch: FontStretch = FontStretch.normal
}

type MarkdownUnderlineStyle = record {
  color: Color? = none
  opacity: Number = 1
  width: Number? = none
  offset: Number = 0
  dash: String = ""
}

type MarkdownQuoteStyle = record {
  color: Color? = none
  inset: Number = 14
  pad_x: Number = 16
  pad_y: Number = 8
  fill: Color? = none
  radius: Number = 4
  bar_color: Color? = c"0.55,0.60,0.68"
  bar_width: Number = 3
  bar_dash: String = ""
}

type TextMathStyle = record {
  scale: Number = 1
  inline_spacing: Number = 0.08
  display_gap: Number = 0.2
  display_fit: MathFit = MathFit.none
  align: Align = Align.center
}

type MarkdownListStyle = record {
  inset: Number = 8
  indent: Number = 26
}

type MarkdownTableStyle = record {
  cell_pad_x: Number = 10
  cell_pad_y: Number = 7
  border: Color = c"0.82,0.84,0.88"
  line_width: Number = 0.8
  header_fill: Color = c"0.94,0.96,0.98"
  alt_row_fill: Color? = none
}

type MarkdownCodeStyle = record {
  size: Number = 15
  line_height: Number = 20
  highlight_fill: Color? = c"#fff2a8"
  chrome: ChromeStyle = ChromeStyle { pad_x = 12 pad_y = 10 }
  colors: CodeColors = CodeColors {}
}

type MarkdownStyle = record {
  bold_color: Color? = none
  highlight_fill: Color? = c"#fff2a8"
  underline: MarkdownUnderlineStyle = MarkdownUnderlineStyle {}
  quote: MarkdownQuoteStyle = MarkdownQuoteStyle {}
  block_gap: Number = 8
  list: MarkdownListStyle = MarkdownListStyle {}
  code: MarkdownCodeStyle = MarkdownCodeStyle {}
  table: MarkdownTableStyle = MarkdownTableStyle {}
}

type TextStyle = record {
  parse: TextParseMode = TextParseMode.inline
  font: FontFace = FontFace { family = "Helvetica" }
  bold_weight: Number = 700
  italic_style: FontStyle = FontStyle.italic
  code_font: FontFace = FontFace { family = "monospace" }
  size: Number = 20
  line_height: Number? = none
  color: Color = c"0.08,0.08,0.08"
  link_color: Color = c"0.1,0.25,0.75"
  emoji_spacing: Number = 0.12
  markdown: MarkdownStyle = MarkdownStyle {}
  math: TextMathStyle = TextMathStyle {}
}

type MarkdownHeadingStyle = record {
  text: TextStyle = TextStyle {}
}

type MarkdownHeadingStyles = record {
  h1: MarkdownHeadingStyle? = none
  h2: MarkdownHeadingStyle? = none
  h3: MarkdownHeadingStyle? = none
  h4: MarkdownHeadingStyle? = none
  h5: MarkdownHeadingStyle? = none
  h6: MarkdownHeadingStyle? = none
}

type UnderlineStyle = record {
  color: Color? = none
  width: Number = 1
  offset: Number = -2
}

type RuleStyle = record {
  stroke: Color? = none
  line_width: Number = 1
  dash: String = ""
}
