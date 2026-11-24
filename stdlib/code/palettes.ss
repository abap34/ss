import std:code/types as { CodeColors, CodeHighlightTheme }

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
      addition = c"#1a7f37"
      deletion = c"#cf222e"
      change = c"#9a6700"
      addition_fill = c"#dafbe1"
      deletion_fill = c"#ffebe9"
      change_fill = c"#fff8c5"
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
      addition = c"#7ee787"
      deletion = c"#ff7b72"
      change = c"#d29922"
      addition_fill = c"#0f2d1a"
      deletion_fill = c"#3d1c1e"
      change_fill = c"#392e12"
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
      addition = c"#859900"
      deletion = c"#dc322f"
      change = c"#b58900"
      addition_fill = c"#e8edce"
      deletion_fill = c"#f8ded5"
      change_fill = c"#f5e9c7"
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
      addition = c"#859900"
      deletion = c"#dc322f"
      change = c"#b58900"
      addition_fill = c"#203b28"
      deletion_fill = c"#3f2830"
      change_fill = c"#3b3820"
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
      addition = c"#98c379"
      deletion = c"#e06c75"
      change = c"#e5c07b"
      addition_fill = c"#303e32"
      deletion_fill = c"#462f35"
      change_fill = c"#454034"
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
      addition = c"#a6e22e"
      deletion = c"#f92672"
      change = c"#e6db74"
      addition_fill = c"#354025"
      deletion_fill = c"#482735"
      change_fill = c"#45412b"
    }
    fill = c"#272822"
    stroke = c"#49483e"
  }
end
