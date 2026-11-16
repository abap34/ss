import std:layout/types as { Align }
import std:math/types as { MathFit }

enum SemanticRole { auto paragraph heading code figure caption }

type TextSemantics {
  role: SemanticRole = SemanticRole.auto
  heading_level: Number? = none
}

enum TextParseMode { none plain inline block }
enum FontStyle { normal oblique italic }
enum FontStretch { ultra_condensed extra_condensed condensed semi_condensed normal semi_expanded expanded extra_expanded ultra_expanded }

type FontFace {
  family: String = "Helvetica"
  weight: Number = 400
  style: FontStyle = FontStyle.normal
  stretch: FontStretch = FontStretch.normal
}

type FontOverride {
  family: String? = none
  weight: Number? = none
  style: FontStyle? = none
  stretch: FontStretch? = none
}

type TypographyOverride {
  font: FontOverride = FontOverride {}
  size: Number? = none
  line_height: Number? = none
  color: Color? = none
  align: Align? = none
  emoji_spacing: Number? = none
}

type HeadingLevels {
  h1: TypographyOverride = TypographyOverride { size = 36 font = FontOverride { weight = 700 } }
  h2: TypographyOverride = TypographyOverride { size = 30 font = FontOverride { weight = 700 } }
  h3: TypographyOverride = TypographyOverride { size = 26 font = FontOverride { weight = 700 } }
  h4: TypographyOverride = TypographyOverride { size = 23 font = FontOverride { weight = 700 } }
  h5: TypographyOverride = TypographyOverride { size = 20 font = FontOverride { weight = 700 } }
  h6: TypographyOverride = TypographyOverride { size = 18 font = FontOverride { weight = 700 } }
}

type BoldAppearance {
  weight: Number = 700
  color: Color? = none
}

type ItalicAppearance {
  style: FontStyle = FontStyle.italic
}

type LinkAppearance {
  color: Color? = c"0.1,0.25,0.75"
}

type MarkdownUnderlineStyle {
  color: Color? = none
  opacity: Number = 1
  width: Number? = none
  offset: Number = 0
  dash: String = ""
}

type QuoteBar {
  color: Color? = c"0.55,0.60,0.68"
  width: Number = 3
  dash: String = ""
}

type QuoteAppearance {
  color: Color? = none
  inset: Number = 14
  pad_x: Number = 16
  pad_y: Number = 8
  fill: Color? = none
  radius: Number = 4
  bar: QuoteBar = QuoteBar {}
}

type ListAppearance {
  inset: Number = 8
  indent: Number = 26
}

type TableAppearance {
  cell_pad_x: Number = 10
  cell_pad_y: Number = 7
  border: Color = c"0.82,0.84,0.88"
  line_width: Number = 0.8
  header_fill: Color = c"0.94,0.96,0.98"
  alt_row_fill: Color? = none
}

type MarkdownAppearance {
  bold: BoldAppearance = BoldAppearance {}
  italic: ItalicAppearance = ItalicAppearance {}
  link: LinkAppearance = LinkAppearance {}
  highlight_fill: Color? = c"#fff2a8"
  underline: MarkdownUnderlineStyle = MarkdownUnderlineStyle {}
  block_gap: Number = 8
  quote: QuoteAppearance = QuoteAppearance {}
  list: ListAppearance = ListAppearance {}
  table: TableAppearance = TableAppearance {}
}

type TextMathStyle {
  scale: Number = 1
  inline_spacing: Number = 0.08
  display_gap: Number = 0.2
  display_fit: MathFit = MathFit.none
  align: Align = Align.center
}
