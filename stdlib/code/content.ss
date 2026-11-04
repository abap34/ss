import std:code/style as { CodeBlockStyle }
import std:text/content as { Text, TextContent, TextContentKind }
import std:text/style as { TextBlockStyle }
import std:text/types as { TextSemantics, SemanticRole }

type Code {
  source: String
  language: String = "plain"
  style: CodeBlockStyle = CodeBlockStyle {}
}

fn display(self: Placed<Code>) -> Text
  return Text {
    content = TextContent {
      kind = TextContentKind.code
      source = self.value.source
      language = self.value.language
      highlight = self.value.style.highlight
    }
    style = TextBlockStyle {
      text = self.value.style.text
      layout = self.value.style.layout
      chrome = self.value.style.chrome
    }
    semantics = TextSemantics { role = SemanticRole.code }
  }
end
