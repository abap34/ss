import std:code/content as { Code }
import std:text/style as { TextBlockStyle }
import std:code/style as { CodeAppearance }
import std:code/types as { CodeColors, CodeHighlightTheme }
import std:code/palettes as { code_theme_github_light, code_theme_github_dark, code_theme_solarized_light, code_theme_solarized_dark, code_theme_one_dark, code_theme_monokai }

fn/! code(source: String, language: String = "plain", style: TextBlockStyle? = none, highlight_lines: String = "") -> Code
  return Code { source = source language = language style = style highlight_lines = highlight_lines }
end

fn/! code_file(path: String, language: String = "plain", style: TextBlockStyle? = none, highlight_lines: String = "") -> Code
  return code(readlines(path), language, style, highlight_lines)
end
