import std:text/types as { TextStyle, UnderlineStyle, MarkdownHeadingStyles, TextParseMode }
import std:code/palettes as palette
import std:layout/types as { LayoutStyle }
import std:graphics/paint/types as { ChromeStyle }

type TextBlockStyle {
  text: TextStyle = TextStyle {}
  layout: LayoutStyle = LayoutStyle {}
  underline: UnderlineStyle = UnderlineStyle {}
  headings: MarkdownHeadingStyles = MarkdownHeadingStyles {}
  chrome: ChromeStyle = ChromeStyle {}
}

const default_text_style: TextBlockStyle = TextBlockStyle {
  text = palette::text_with_code_theme(TextStyle { parse = TextParseMode.block }, palette::code_theme_github_light())
}
