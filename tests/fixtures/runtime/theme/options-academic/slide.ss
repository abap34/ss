import std:themes/academic as *
import std:theme/types as theme_base

document
  set_theme(default_theme(theme_base::ThemeOptions {
    font_family = "Academic Sans"
    code_font_family = "Academic Mono"
    text_color = c"#183048"
    accent_color = c"#2868a8"
    muted_color = c"#687888"
  }))
end

page academic_title
  title!("AcademicTitle")
  subtitle!("AcademicSubtitle")
  byline!("AcademicAuthor")
end

page academic_body
  head!("AcademicHead")
  text!("AcademicBody with `code`.")
  annotate!("Before Target after", "Target", "AcademicCallout")
  pageno!()
end
