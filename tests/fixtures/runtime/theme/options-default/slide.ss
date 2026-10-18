import std:themes/default as base

const theme: Theme = base::default_theme(ThemeOptions {
  font_family = "Fixture Sans"
  code_font_family = "Fixture Mono"
  text_color = c"#102030"
  accent_color = c"#2468ac"
  muted_color = c"#708090"
})

page title_settings
  text!("SettingsTitle", theme.h1)
  text!("SettingsAuthor", theme.byline)
end
page body_settings
  let heading = heading!("SettingsHead", 1, theme.h1 with { text.color = c"#2468ac" })
  let body = text!("## SettingsHeading
SettingsBody with `inline code`.", theme.body)
  let original = text!("OriginalTheme", base::default_theme().body)
  let font_only = text!("FontOnly", base::default_theme(ThemeOptions { font_family = "Fixture Sans" }).body)
  ~ body.top == heading.bottom - 24
  ~ original.top == body.bottom - 24
  ~ font_only.top == original.bottom - 24
  let number = pageno!(theme.page_number)
  ~ number.right == page.right - 24
  ~ number.bottom == page.bottom + 20
end
