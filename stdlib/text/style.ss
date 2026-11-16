import std:text/types as { FontFace, HeadingLevels, MarkdownAppearance, TextMathStyle }
import std:layout/types as { Align, TextLayout }
import std:graphics/paint/types as { BoxStyle }
import std:code/style as { CodeAppearance }
import std:code/palettes as palette

type TextBlockStyle {
  font: FontFace = FontFace {}
  size: Number = 20
  line_height: Number? = none
  color: Color = c"0.08,0.08,0.08"
  align: Align = Align.left
  emoji_spacing: Number = 0.12
  layout: TextLayout = TextLayout {}
  chrome: BoxStyle = BoxStyle {}
  headings: HeadingLevels = HeadingLevels {}
  code: CodeAppearance = CodeAppearance {}
  markdown: MarkdownAppearance = MarkdownAppearance {}
  math: TextMathStyle = TextMathStyle {}
}

const default_text_style: TextBlockStyle = TextBlockStyle {} with { code.colors = palette::code_theme_github_light().code }
