import std:document/settings as settings
import std:theme/types as { ThemeOptions, Theme }

const base_theme: Theme = Theme {}

fn theme!(value: Theme) -> Void
  define_theme!(value)
end

fn document_theme() -> Theme = docctx().theme ?? base_theme

fn theme_for(page: Page) -> Theme = page.theme ?? document_theme()
