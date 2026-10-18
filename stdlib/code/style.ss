import std:text/types as { TextStyle, TextParseMode, FontFace }
import std:layout/types as { LayoutStyle, WrapMode }
import std:code/types as { CodeHighlightTheme }
import std:code/palettes as palette
import std:graphics/paint/types as { ChromeStyle }

type CodeBlockStyle {
  text: TextStyle = TextStyle {
    parse = TextParseMode.none
    font = FontFace { family = "monospace" }
    code_font = FontFace { family = "monospace" }
    size = 16
  }
  layout: LayoutStyle = LayoutStyle { wrap = WrapMode.off }
  highlight: CodeHighlightTheme = palette::code_theme_github_light()
  chrome: ChromeStyle = ChromeStyle {}
}
