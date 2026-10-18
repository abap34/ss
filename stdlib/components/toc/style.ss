import std:text/style as { TextBlockStyle }
import std:text/types as { TextParseMode }

type TocStyle {
  title: TextBlockStyle = TextBlockStyle {} with { text.size = 36 }
  body: TextBlockStyle = TextBlockStyle {} with { text.parse = TextParseMode.none }
}
