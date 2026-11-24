import std:text/style as { TextBlockStyle, default_text_style }
import std:math/types as { LatexConfig }
import std:text/content as { Text, TextContent, TextContentKind, text_content }
import std:text/types as { SemanticRole, TextSemantics, TextParseMode, FontStyle, FontStretch, FontFace, FontOverride, TypographyOverride, HeadingLevels, BoldAppearance, ItalicAppearance, LinkAppearance, InlineCodeAppearance, MarkdownUnderlineStyle, QuoteBar, QuoteAppearance, ListAppearance, TableAppearance, MarkdownAppearance, TextMathStyle }

;; Exactly one line feed; quoted strings preserve their contents literally.
const NEWLINE: String = "
"

fn/! text(content: String, style: TextBlockStyle? = none, config: LatexConfig = LatexConfig {}, parse: TextParseMode = TextParseMode.block) -> Text
  return Text { content = text_content(content, config, parse) style = style }
end
