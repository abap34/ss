import std:text/style as { TextBlockStyle, default_text_style }
import std:math/types as { LatexConfig }
import std:text/content as { Text, TextContent, TextContentKind, text_content }
import std:text/types as { SemanticRole, TextSemantics, TextParseMode, FontStyle, FontStretch, FontFace, MarkdownUnderlineStyle, MarkdownQuoteStyle, TextMathStyle, MarkdownListStyle, MarkdownTableStyle, MarkdownCodeStyle, MarkdownStyle, TextStyle, MarkdownHeadingStyle, MarkdownHeadingStyles, UnderlineStyle, RuleStyle }

;; Exactly one line feed; quoted strings preserve their contents literally.
const NEWLINE: String = "
"

fn/! text(content: String, style: TextBlockStyle = default_text_style, config: LatexConfig = LatexConfig {}) -> Text
  return Text { content = text_content(content, config) style = style }
end
