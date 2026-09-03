import std:themes/default as *

document
  theme!(default_theme(ThemeOptions {
    font_family = "Fixture Sans"
    code_font_family = "Fixture Mono"
    text_color = c"#102030"
    accent_color = c"#2468ac"
    muted_color = c"#708090"
  }) with {
    head.gap = 12
  })
end

page cover_settings
  cover!("SettingsCover", "SettingsSubtitle", "SettingsAuthor")
end

page body_settings
  let heading = head! "SettingsHead"
  let body = text! <<
## SettingsHeading
SettingsBody with `inline code`.
>>
  let original = text!("OriginalTheme", default_theme())
  let font_only = text!("FontOnly", default_theme(ThemeOptions {
    font_family = "Fixture Sans"
  }))
  ~ body.top == heading.bottom - 24
  ~ original.top == body.bottom - 24
  ~ font_only.top == original.bottom - 24
  annotate!("Before Target after", "Target", "SettingsCallout")
  pageno!()
end
