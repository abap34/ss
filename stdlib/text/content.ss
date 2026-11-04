import std:text/style as { TextBlockStyle, default_text_style }
import std:text/types as { TextSemantics }
import std:math/types as { LatexConfig }
import std:code/types as { CodeHighlightTheme }

enum TextContentKind { text code }

type TextContent {
  kind: TextContentKind = TextContentKind.text
  source: String
  config: LatexConfig = LatexConfig {}
  language: String = "plain"
  highlight: CodeHighlightTheme = CodeHighlightTheme {}
}

fn text_content(source: String, config: LatexConfig = LatexConfig {}) -> TextContent
  return TextContent { source = source config = config }
end

type Text {
  content: TextContent
  style: TextBlockStyle = default_text_style
  semantics: TextSemantics = TextSemantics {}
}
