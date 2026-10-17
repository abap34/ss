import std:internal/classes
import std:text/style

type TocStyle = record {
  title: TextBlockStyle = TextBlockStyle {}
  body: TextBlockStyle = TextBlockStyle {}
  chrome: ChromeStyle = ChromeStyle {}
}
