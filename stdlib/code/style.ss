import std:text/types as { TextStyle }
import std:layout/types as { LayoutStyle }
import std:code/types as { CodeHighlightTheme }
import std:graphics/paint/types as { ChromeStyle }

type CodeBlockStyle {
  text: TextStyle = TextStyle {}
  layout: LayoutStyle = LayoutStyle {}
  highlight: CodeHighlightTheme = CodeHighlightTheme {}
  chrome: ChromeStyle = ChromeStyle {}
}
