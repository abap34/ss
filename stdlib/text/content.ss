import std:text/style as { TextBlockStyle, default_text_style }
import std:text/types as { TextSemantics }
import std:math/types as { LatexConfig }

type Text {
  content: String
  style: TextBlockStyle = default_text_style
  config: LatexConfig = LatexConfig {}
  semantics: TextSemantics = TextSemantics {}
}
