import std:text/types as { MarkdownAppearance, TableAppearance, ListAppearance, QuoteAppearance, MarkdownUnderlineStyle, InlineCodeAppearance }

fn link(label: String, href: String) -> String
  return "[" ++ label ++ "](" ++ href ++ ")"
end
