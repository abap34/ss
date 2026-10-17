import std:code/style as { CodeBlockStyle }
import std:code/types as { CodeColors, CodeHighlightTheme }
import std:code/palettes as { code_theme_github_light, code_theme_github_dark, code_theme_solarized_light, code_theme_solarized_dark, code_theme_one_dark, code_theme_monokai }
import std:theme as theme
import std:internal/objects as objects
import std:internal/style as styles

fn/! code(source: String, language: String = "plain", style: CodeBlockStyle = theme::current_theme().code) -> Object
  let result = objects::code_obj(source)
  result.language = language
  return styles::apply_code_block_style(result, style)
end

fn/! code_file(path: String, language: String = "plain", style: CodeBlockStyle = theme::current_theme().code) -> Object
  return code(readlines(path), language, style)
end
