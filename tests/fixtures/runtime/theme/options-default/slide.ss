import std:themes/default as base

const theme: Theme = base::default_theme(ThemeOptions {
  font_family = "Fixture Sans"
  code_font_family = "Fixture Mono"
  text_color = c"#102030"
  accent_color = c"#2468ac"
  muted_color = c"#708090"
})

document
  theme!(theme)
end

page title_settings
  text!("SettingsTitle", theme.text)
  text!("SettingsAuthor", theme.text)
end
page body_settings
  let heading = heading!("SettingsHead", 1, theme.text with { color = c"#2468ac" })
  let body = text!("## SettingsHeading
SettingsBody with `inline code`.", theme.text)
  let original = text!("OriginalTheme", base::default_theme().text)
  let font_only = text!("FontOnly", base::default_theme(ThemeOptions { font_family = "Fixture Sans" }).text)
  ~ body.top == heading.bottom - 24
  ~ original.top == body.bottom - 24
  ~ font_only.top == original.bottom - 24
  let number = pageno!()
  ~ number.right == page.right - 24
  ~ number.bottom == page.bottom + 20
end
