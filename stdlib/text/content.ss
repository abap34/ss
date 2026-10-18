import std:text/types as { TextStyle, TextParseMode }
import std:text/style as { TextBlockStyle }

type Text {
  content: String
  style: TextBlockStyle = TextBlockStyle {
    text = TextStyle { parse = TextParseMode.block }
  }
}
