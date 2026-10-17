import std:internal/classes
import std:theme/types as { GeneratedStyle, ThemeOptions, Theme }
import std:themes/default as defaults

extend Doc {
  theme: Theme? = none
}

fn set_theme(theme_value: Theme) -> Void
  docctx().theme = theme_value
end

fn current_theme() -> Theme
  return docctx().theme ?? defaults::default_theme()
end
