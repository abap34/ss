import std:theme as { theme_for }
import std:text/style as { TextBlockStyle }
import std:text/types as { TextSemantics, TextParseMode }
import std:math/types as { LatexConfig }

enum TextContentKind { text code }

type TextContent {
  kind: TextContentKind = TextContentKind.text
  source: String
  parse: TextParseMode = TextParseMode.block
  config: LatexConfig = LatexConfig {}
  language: String = "plain"
  highlight_lines: String = ""
  heading_level: Number? = none
}

fn text_content(source: String, config: LatexConfig = LatexConfig {}, parse: TextParseMode = TextParseMode.block) -> TextContent
  return TextContent { source = source config = config parse = parse }
end

type Text {
  content: TextContent
  style: TextBlockStyle? = none
  semantics: TextSemantics = TextSemantics {}
}

fn display(self: Placed<Text>) -> Text
  return self.value with { style = self.value.style ?? theme_for(self.page).text }
end
