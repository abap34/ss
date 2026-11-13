import std:theme as { theme_for }
import std:code/style as { CodeBlockStyle }
import std:text/content as { Text, TextContent, TextContentKind }
import std:text/style as { TextBlockStyle }
import std:text/types as { TextSemantics, SemanticRole }

type Code {
  source: String
  language: String = "plain"
  style: CodeBlockStyle? = none
}

fn display(self: Placed<Code>) -> Text
  let style = self.value.style ?? theme_for(self.page).code
  return Text {
    content = TextContent {
      kind = TextContentKind.code
      source = self.value.source
      language = self.value.language
      highlight = style.highlight
    }
    style = TextBlockStyle {
      text = style.text
      layout = style.layout
      chrome = style.chrome
    }
    semantics = TextSemantics { role = SemanticRole.code }
  }
end
