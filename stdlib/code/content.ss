import std:theme as { theme_for }
import std:text/content as { Text, TextContent, TextContentKind }
import std:text/style as { TextBlockStyle }
import std:text/types as { TextParseMode, TextSemantics, SemanticRole }

type Code {
  source: String
  language: String = "plain"
  highlight_lines: String = ""
  style: TextBlockStyle? = none
}

fn display(self: Placed<Code>) -> Text
  let base = self.value.style ?? theme_for(self.page).text
  return Text {
    content = TextContent { kind = TextContentKind.code source = self.value.source language = self.value.language highlight_lines = self.value.highlight_lines parse = TextParseMode.none }
    style = base
    semantics = TextSemantics { role = SemanticRole.code }
  }
end
