import std:text/style as { TextBlockStyle, default_text_style }
import std:math/types as { LatexConfig }
import std:text/content as { Text }
import std:text/types as { SemanticRole, TextSemantics, TextParseMode, FontStyle, FontStretch, FontFace, MarkdownUnderlineStyle, MarkdownQuoteStyle, TextMathStyle, MarkdownListStyle, MarkdownTableStyle, MarkdownCodeStyle, MarkdownStyle, TextStyle, MarkdownHeadingStyle, MarkdownHeadingStyles, UnderlineStyle, RuleStyle }

fn/! text(content: String, style: TextBlockStyle = default_text_style, config: LatexConfig = LatexConfig {}) -> Text
  return Text { content = content style = style config = config }
end
