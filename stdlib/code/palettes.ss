import std:code/types as { CodeColors, CodeHighlightTheme }
import std:text/types as { TextStyle }

fn code_theme_github_light() -> CodeHighlightTheme
  return CodeHighlightTheme {
    code = CodeColors {
      plain = c"#24292f"
      keyword = c"#cf222e"
      function = c"#8250df"
      type_name = c"#953800"
      constant = c"#0550ae"
      number = c"#0550ae"
      variable = c"#24292f"
      operator = c"#0550ae"
      comment = c"#6e7781"
      string = c"#0a3069"
    }
    fill = c"#f6f8fa"
    stroke = c"#d0d7de"
  }
end

fn code_theme_github_dark() -> CodeHighlightTheme
  return CodeHighlightTheme {
    code = CodeColors {
      plain = c"#c9d1d9"
      keyword = c"#ff7b72"
      function = c"#d2a8ff"
      type_name = c"#ffa657"
      constant = c"#79c0ff"
      number = c"#79c0ff"
      variable = c"#c9d1d9"
      operator = c"#79c0ff"
      comment = c"#8b949e"
      string = c"#a5d6ff"
    }
    fill = c"#0d1117"
    stroke = c"#30363d"
  }
end

fn code_theme_solarized_light() -> CodeHighlightTheme
  return CodeHighlightTheme {
    code = CodeColors {
      plain = c"#657b83"
      keyword = c"#859900"
      function = c"#268bd2"
      type_name = c"#b58900"
      constant = c"#2aa198"
      number = c"#d33682"
      variable = c"#657b83"
      operator = c"#859900"
      comment = c"#93a1a1"
      string = c"#2aa198"
    }
    fill = c"#fdf6e3"
    stroke = c"#eee8d5"
  }
end

fn code_theme_solarized_dark() -> CodeHighlightTheme
  return CodeHighlightTheme {
    code = CodeColors {
      plain = c"#839496"
      keyword = c"#859900"
      function = c"#268bd2"
      type_name = c"#b58900"
      constant = c"#2aa198"
      number = c"#d33682"
      variable = c"#839496"
      operator = c"#859900"
      comment = c"#586e75"
      string = c"#2aa198"
    }
    fill = c"#002b36"
    stroke = c"#073642"
  }
end

fn code_theme_one_dark() -> CodeHighlightTheme
  return CodeHighlightTheme {
    code = CodeColors {
      plain = c"#abb2bf"
      keyword = c"#c678dd"
      function = c"#61afef"
      type_name = c"#e5c07b"
      constant = c"#d19a66"
      number = c"#d19a66"
      variable = c"#abb2bf"
      operator = c"#56b6c2"
      comment = c"#5c6370"
      string = c"#98c379"
    }
    fill = c"#282c34"
    stroke = c"#3e4451"
  }
end

fn code_theme_monokai() -> CodeHighlightTheme
  return CodeHighlightTheme {
    code = CodeColors {
      plain = c"#f8f8f2"
      keyword = c"#f92672"
      function = c"#a6e22e"
      type_name = c"#66d9ef"
      constant = c"#ae81ff"
      number = c"#ae81ff"
      variable = c"#f8f8f2"
      operator = c"#f92672"
      comment = c"#75715e"
      string = c"#e6db74"
    }
    fill = c"#272822"
    stroke = c"#49483e"
  }
end

fn text_with_code_theme(text: TextStyle, theme: CodeHighlightTheme) -> TextStyle
  let colors = text.markdown.code.colors
  return text with {
    markdown.code.colors = CodeColors {
      plain = colors.plain ?? theme.code.plain
      keyword = colors.keyword ?? theme.code.keyword
      function = colors.function ?? theme.code.function
      type_name = colors.type_name ?? theme.code.type_name
      constant = colors.constant ?? theme.code.constant
      number = colors.number ?? theme.code.number
      variable = colors.variable ?? theme.code.variable
      operator = colors.operator ?? theme.code.operator
      comment = colors.comment ?? theme.code.comment
      string = colors.string ?? theme.code.string
    }
  }
end
