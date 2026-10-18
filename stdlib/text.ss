import std:text/style as { TextBlockStyle, default_text_style }
import std:math/types as { LatexConfig }
import std:text/content as { Text }
import std:text/types as { SemanticRole, SemanticStyle, RenderKind, TextParseMode, FontStyle, FontStretch, FontFace, MarkdownUnderlineStyle, MarkdownQuoteStyle, TextMathStyle, MarkdownListStyle, MarkdownTableStyle, MarkdownCodeStyle, MarkdownStyle, TextStyle, MarkdownHeadingStyle, MarkdownHeadingStyles, UnderlineStyle, RuleStyle }
import std:theme as theme
import std:internal/style as styles

fn/! text(content: String, style: TextBlockStyle = default_text_style, config: LatexConfig = LatexConfig {}) -> Text
  return Text { content = content style = style config = config }
end

fn/! title(content: String, style: TextBlockStyle = theme::current_theme().h1) -> Object
  return styles::text_object(content, "title", style)
end

fn/! subtitle(content: String, style: TextBlockStyle = theme::current_theme().h2) -> Object
  return styles::text_object(content, "subtitle", style)
end

fn/! note(content: String, style: TextBlockStyle = theme::current_theme().note) -> Object
  return styles::text_object(content, "note", style)
end

fn/! byline(content: String, style: TextBlockStyle = theme::current_theme().byline) -> Object
  return styles::text_object(content, "byline", style)
end

fn/! label(content: String, style: TextBlockStyle = theme::current_theme().label) -> Object
  return styles::text_object(content, "label", style)
end

fn/! h1(content: String, style: TextBlockStyle = theme::current_theme().h1) -> Object
  return styles::text_object(content, "title", style)
end

fn/! h2(content: String, style: TextBlockStyle = theme::current_theme().h2) -> Object
  return styles::text_object(content, "subtitle", style)
end

fn/! h3(content: String, style: TextBlockStyle = theme::current_theme().h3) -> Object
  let result = styles::text_object(content, "subtitle", style)
  result.semantics = SemanticStyle { role = SemanticRole.heading heading_level = 3 }
  return result
end

fn/! h4(content: String, style: TextBlockStyle = theme::current_theme().h4) -> Object
  let result = styles::text_object(content, "subtitle", style)
  result.semantics = SemanticStyle { role = SemanticRole.heading heading_level = 4 }
  return result
end

fn/! h5(content: String, style: TextBlockStyle = theme::current_theme().h5) -> Object
  let result = styles::text_object(content, "subtitle", style)
  result.semantics = SemanticStyle { role = SemanticRole.heading heading_level = 5 }
  return result
end

fn/! h6(content: String, style: TextBlockStyle = theme::current_theme().h6) -> Object
  let result = styles::text_object(content, "subtitle", style)
  result.semantics = SemanticStyle { role = SemanticRole.heading heading_level = 6 }
  return result
end
