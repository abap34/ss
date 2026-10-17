import std:text/types as { MarkdownStyle, MarkdownCodeStyle, MarkdownTableStyle, MarkdownListStyle, MarkdownQuoteStyle, MarkdownUnderlineStyle }

fn link(label: String, href: String) -> String
  return "[" ++ label ++ "](" ++ href ++ ")"
end
