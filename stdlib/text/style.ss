import std:text/types as { TextStyle, UnderlineStyle, MarkdownHeadingStyles }
import std:layout/types as { LayoutStyle }

type TextBlockStyle {
  text: TextStyle = TextStyle {}
  layout: LayoutStyle = LayoutStyle {}
  underline: UnderlineStyle = UnderlineStyle {}
  headings: MarkdownHeadingStyles = MarkdownHeadingStyles {}
}
