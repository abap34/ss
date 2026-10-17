import std:themes/pop as *
import std:theme/types as theme_base

document
  set_theme(default_theme(theme_base::ThemeOptions {
    font_family = "Pop Sans"
    code_font_family = "Pop Mono"
    text_color = c"#203850"
    accent_color = c"#3878b8"
    muted_color = c"#708090"
  }))
end

page pop_title
  title!("PopTitle")
  subtitle!("PopSubtitle")
  byline!("PopAuthor")
end

page pop_body
  head!("PopHead")
  text!("PopBody with `code`.")
  annotate!("Before Target after", "Target", "PopCallout")
  pageno!()
end
