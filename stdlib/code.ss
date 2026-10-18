import std:code/content as { Code }
import std:code/style as { CodeBlockStyle }
import std:code/types as { CodeColors, CodeHighlightTheme }
import std:code/palettes as { code_theme_github_light, code_theme_github_dark, code_theme_solarized_light, code_theme_solarized_dark, code_theme_one_dark, code_theme_monokai }

fn/! code(source: String, language: String = "plain", style: CodeBlockStyle = CodeBlockStyle {}) -> Code
  return Code { source = source language = language style = style }
end

fn/! code_file(path: String, language: String = "plain", style: CodeBlockStyle = CodeBlockStyle {}) -> Code
  return code(readlines(path), language, style)
end
