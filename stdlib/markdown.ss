import std:text/types as { MarkdownAppearance, TableAppearance, ListAppearance, QuoteAppearance, MarkdownUnderlineStyle }

fn link(label: String, href: String) -> String
  return "[" ++ label ++ "](" ++ href ++ ")"
end
