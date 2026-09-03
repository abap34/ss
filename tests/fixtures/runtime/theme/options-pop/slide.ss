import std:themes/pop as *

document
  theme!(default_theme(ThemeOptions {
    font_family = "Pop Sans"
    code_font_family = "Pop Mono"
    text_color = c"#203850"
    accent_color = c"#3878b8"
    muted_color = c"#708090"
  }))
end

page pop_cover
  cover!("PopCover", "PopSubtitle", "PopAuthor")
end

page pop_body
  head!("PopHead")
  text!("PopBody with `code`.")
  annotate!("Before Target after", "Target", "PopCallout")
  pageno!()
end
