import std:text/types as { TextStyle, TextParseMode }

type Text {
  content: String
  style: TextStyle = TextStyle { parse = TextParseMode.block }
}
