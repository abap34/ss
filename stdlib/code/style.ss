import std:internal/classes
import std:text/style

type CodeBlockStyle = record {
  text: TextStyle = TextStyle {}
  layout: LayoutStyle = LayoutStyle {}
  highlight: CodeHighlightTheme = CodeHighlightTheme {}
  chrome: ChromeStyle = ChromeStyle {}
}
