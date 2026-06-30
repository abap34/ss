import std:core/classes as classes
import std:core/objects as objects

fn tex_preamble(src: String) -> Void
  extend_render_env(docctx(), "add", "math.tex.preamble", src)
end

fn page_tex_preamble(src: String) -> Void
  extend_render_env(pagectx(), "add", "math.tex.preamble", src)
end

fn tex_preamble_file(path: String) -> Void
  extend_render_env(docctx(), "add", "math.tex.preamble.file", path)
end

fn page_tex_preamble_file(path: String) -> Void
  extend_render_env(pagectx(), "add", "math.tex.preamble.file", path)
end

fn link(obj: Object, id: String) -> Object
  obj.link_id = id
  return obj
end

fn md_link(label: String, href: String) -> String
  return "[" ++ label ++ "](" ++ href ++ ")"
end

fn scale(obj: Object, factor: Number) -> Object
  obj.asset_scale = factor
  return obj
end

fn md_code(obj: Object, font_size_name: Number, line_height_name: Number, pad_x_name: Number, pad_y_name: Number, fill_name: Color?, stroke_name: Color?, line_width_name: Number, radius_name: Number) -> Object
  obj.text_markdown_code_font_size = font_size_name
  obj.text_markdown_code_line_height = line_height_name
  obj.text_markdown_code_pad_x = pad_x_name
  obj.text_markdown_code_pad_y = pad_y_name
  obj.text_markdown_code_fill = fill_name
  obj.text_markdown_code_stroke = stroke_name
  obj.text_markdown_code_line_width = line_width_name
  obj.text_markdown_code_radius = radius_name
  return obj
end

fn code_theme_github_light() -> CodeHighlightTheme
  return CodeHighlightTheme {
    code = CodeStyle {
      plain_color = c"#24292f"
      keyword_color = c"#cf222e"
      function_color = c"#8250df"
      type_color = c"#953800"
      constant_color = c"#0550ae"
      number_color = c"#0550ae"
      variable_color = c"#24292f"
      operator_color = c"#0550ae"
      comment_color = c"#6e7781"
      string_color = c"#0a3069"
    }
    fill = c"#f6f8fa"
    stroke = c"#d0d7de"
  }
end

fn code_theme_github_dark() -> CodeHighlightTheme
  return CodeHighlightTheme {
    code = CodeStyle {
      plain_color = c"#c9d1d9"
      keyword_color = c"#ff7b72"
      function_color = c"#d2a8ff"
      type_color = c"#ffa657"
      constant_color = c"#79c0ff"
      number_color = c"#79c0ff"
      variable_color = c"#c9d1d9"
      operator_color = c"#79c0ff"
      comment_color = c"#8b949e"
      string_color = c"#a5d6ff"
    }
    fill = c"#0d1117"
    stroke = c"#30363d"
  }
end

fn code_theme_solarized_light() -> CodeHighlightTheme
  return CodeHighlightTheme {
    code = CodeStyle {
      plain_color = c"#657b83"
      keyword_color = c"#859900"
      function_color = c"#268bd2"
      type_color = c"#b58900"
      constant_color = c"#2aa198"
      number_color = c"#d33682"
      variable_color = c"#657b83"
      operator_color = c"#859900"
      comment_color = c"#93a1a1"
      string_color = c"#2aa198"
    }
    fill = c"#fdf6e3"
    stroke = c"#eee8d5"
  }
end

fn code_theme_solarized_dark() -> CodeHighlightTheme
  return CodeHighlightTheme {
    code = CodeStyle {
      plain_color = c"#839496"
      keyword_color = c"#859900"
      function_color = c"#268bd2"
      type_color = c"#b58900"
      constant_color = c"#2aa198"
      number_color = c"#d33682"
      variable_color = c"#839496"
      operator_color = c"#859900"
      comment_color = c"#586e75"
      string_color = c"#2aa198"
    }
    fill = c"#002b36"
    stroke = c"#073642"
  }
end

fn code_theme_one_dark() -> CodeHighlightTheme
  return CodeHighlightTheme {
    code = CodeStyle {
      plain_color = c"#abb2bf"
      keyword_color = c"#c678dd"
      function_color = c"#61afef"
      type_color = c"#e5c07b"
      constant_color = c"#d19a66"
      number_color = c"#d19a66"
      variable_color = c"#abb2bf"
      operator_color = c"#56b6c2"
      comment_color = c"#5c6370"
      string_color = c"#98c379"
    }
    fill = c"#282c34"
    stroke = c"#3e4451"
  }
end

fn code_theme_monokai() -> CodeHighlightTheme
  return CodeHighlightTheme {
    code = CodeStyle {
      plain_color = c"#f8f8f2"
      keyword_color = c"#f92672"
      function_color = c"#a6e22e"
      type_color = c"#66d9ef"
      constant_color = c"#ae81ff"
      number_color = c"#ae81ff"
      variable_color = c"#f8f8f2"
      operator_color = c"#f92672"
      comment_color = c"#75715e"
      string_color = c"#e6db74"
    }
    fill = c"#272822"
    stroke = c"#49483e"
  }
end

fn code_theme(obj: Object, theme: CodeHighlightTheme) -> Object
  let style = theme.code
  obj.code_plain_color = style.plain_color
  obj.code_keyword_color = style.keyword_color
  obj.code_function_color = style.function_color
  obj.code_type_color = style.type_color
  obj.code_constant_color = style.constant_color
  obj.code_number_color = style.number_color
  obj.code_variable_color = style.variable_color
  obj.code_operator_color = style.operator_color
  obj.code_comment_color = style.comment_color
  obj.code_string_color = style.string_color
  obj.text_markdown_code_plain_color = style.plain_color
  obj.text_markdown_code_keyword_color = style.keyword_color
  obj.text_markdown_code_function_color = style.function_color
  obj.text_markdown_code_type_color = style.type_color
  obj.text_markdown_code_constant_color = style.constant_color
  obj.text_markdown_code_number_color = style.number_color
  obj.text_markdown_code_variable_color = style.variable_color
  obj.text_markdown_code_operator_color = style.operator_color
  obj.text_markdown_code_comment_color = style.comment_color
  obj.text_markdown_code_string_color = style.string_color
  return obj
end

fn code_theme_all(theme: CodeHighlightTheme) -> Void
  let style = theme.code
  let doc = docctx()
  doc.code_theme_plain_color = style.plain_color
  doc.code_theme_keyword_color = style.keyword_color
  doc.code_theme_function_color = style.function_color
  doc.code_theme_type_color = style.type_color
  doc.code_theme_constant_color = style.constant_color
  doc.code_theme_number_color = style.number_color
  doc.code_theme_variable_color = style.variable_color
  doc.code_theme_operator_color = style.operator_color
  doc.code_theme_comment_color = style.comment_color
  doc.code_theme_string_color = style.string_color
  doc.code_theme_fill = theme.fill
  doc.code_theme_stroke = theme.stroke
end

fn code_theme_page(theme: CodeHighlightTheme) -> Void
  let style = theme.code
  let page_value = pagectx()
  page_value.code_theme_plain_color = style.plain_color
  page_value.code_theme_keyword_color = style.keyword_color
  page_value.code_theme_function_color = style.function_color
  page_value.code_theme_type_color = style.type_color
  page_value.code_theme_constant_color = style.constant_color
  page_value.code_theme_number_color = style.number_color
  page_value.code_theme_variable_color = style.variable_color
  page_value.code_theme_operator_color = style.operator_color
  page_value.code_theme_comment_color = style.comment_color
  page_value.code_theme_string_color = style.string_color
  page_value.code_theme_fill = theme.fill
  page_value.code_theme_stroke = theme.stroke
end

fn md_bold(obj: Object, color_name: Color?) -> Object
  obj.text_markdown_bold_color = color_name
  return obj
end

fn md_table(obj: Object, pad_x_name: Number, pad_y_name: Number, border_name: Color, line_width_name: Number, header_fill_name: Color, alt_row_fill_name: Color? = none) -> Object
  obj.text_markdown_table_cell_pad_x = pad_x_name
  obj.text_markdown_table_cell_pad_y = pad_y_name
  obj.text_markdown_table_border = border_name
  obj.text_markdown_table_line_width = line_width_name
  obj.text_markdown_table_header_fill = header_fill_name
  obj.text_markdown_table_alt_row_fill = alt_row_fill_name
  return obj
end

fn box(obj: Object, fill_name: Color?, stroke_name: Color?, line_width_name: Number, radius_name: Number) -> Object
  obj.chrome_fill = fill_name
  obj.chrome_stroke = stroke_name
  obj.chrome_line_width = line_width_name
  obj.chrome_radius = radius_name
  return obj
end

fn under(obj: Object, color_name: Color?, line_width_name: Number, offset_name: Number) -> Object
  obj.underline_color = color_name
  obj.underline_width = line_width_name
  obj.underline_offset = offset_name
  return obj
end

fn rule_l(obj: Object, stroke_name: Color?, line_width_name: Number, dash_name: String) -> Object
  obj.rule_stroke = stroke_name
  obj.rule_line_width = line_width_name
  obj.rule_dash = dash_name
  return obj
end

fn fit(obj: Object, policy_name: FitPolicy) -> Object
  obj.fit = policy_name
  return obj
end

fn fit_warn(obj: Object) -> Object
  return fit(obj, FitPolicy.warn)
end

fn fit_error(obj: Object) -> Object
  return fit(obj, FitPolicy.error)
end

fn fit_ignore(obj: Object) -> Object
  return fit(obj, FitPolicy.ignore)
end
