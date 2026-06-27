type LayoutPolicy = top | top_flow | center | center_stack
type RenderKind = text | code | vector_math | vector_asset | raster_asset | chrome_only
type TextParseMode = none | inline | block
type WrapMode = on | off
type FitPolicy = warn | error | ignore
type Align = left | center | right
type FontStyle = normal | oblique | italic
type FontStretch = ultra_condensed | extra_condensed | condensed | semi_condensed | normal | semi_expanded | expanded | extra_expanded | ultra_expanded

record FontFace {
  family: String = "Helvetica"
  weight: Number = 400
  style: FontStyle = FontStyle.normal
  stretch: FontStretch = FontStretch.normal
}

record LayoutStyle {
  font_size: Number? = none
  line_height: Number? = none
  spacing_after: Number = 32
  x: Number = 96
  right_inset: Number = 96
  wrap: WrapMode = WrapMode.on
  fit: FitPolicy = FitPolicy.warn
}

record TextStyle {
  parse: TextParseMode = TextParseMode.inline
  font: FontFace = FontFace { family = "Helvetica" }
  bold_weight: Number = 700
  italic_style: FontStyle = FontStyle.italic
  code_font: FontFace = FontFace { family = "Courier" }
  size: Number = 20
  line_height: Number? = none
  color: Color = c"0.08,0.08,0.08"
  link_color: Color = c"0.1,0.25,0.75"
  markdown_bold_color: Color? = none
  link_underline_width: Number = 0.8
  link_underline_offset: Number = -1.5
  inline_math_height_factor: Number = 1.02
  inline_math_spacing: Number = 0.08
  display_math_height_factor: Number = 2
  math_align: Align = Align.center
  emoji_spacing: Number = 0.12
  markdown_block_gap: Number = 8
  markdown_list_inset: Number = 8
  markdown_list_indent: Number = 26
  markdown_code_font_size: Number = 15
  markdown_code_line_height: Number = 20
  markdown_code_pad_x: Number = 12
  markdown_code_pad_y: Number = 10
  markdown_code_fill: Color? = none
  markdown_code_stroke: Color? = none
  markdown_code_line_width: Number = 1
  markdown_code_radius: Number = 10
  markdown_code_plain_color: Color? = none
  markdown_code_keyword_color: Color? = none
  markdown_code_function_color: Color? = none
  markdown_code_type_color: Color? = none
  markdown_code_constant_color: Color? = none
  markdown_code_number_color: Color? = none
  markdown_code_variable_color: Color? = none
  markdown_code_operator_color: Color? = none
  markdown_code_comment_color: Color? = none
  markdown_code_string_color: Color? = none
  markdown_table_cell_pad_x: Number = 10
  markdown_table_cell_pad_y: Number = 7
  markdown_table_border: Color = c"0.82,0.84,0.88"
  markdown_table_line_width: Number = 0.8
  markdown_table_header_fill: Color = c"0.94,0.96,0.98"
  markdown_table_alt_row_fill: Color? = none
  cjk_bold_passes: Number = 1
  cjk_bold_dx: Number = 0.05
}

record MathStyle {
  scale: Number = 1
  block_line_height: Number = 22
  block_min_height: Number = 30
  block_vertical_padding: Number = 2
  align: Align = Align.center
}

record CodeStyle {
  plain_color: Color = c"0.12,0.12,0.12"
  keyword_color: Color = c"#cf222e"
  function_color: Color = c"#8250df"
  type_color: Color = c"#953800"
  constant_color: Color = c"#0550ae"
  number_color: Color = c"#0550ae"
  variable_color: Color = c"0.12,0.12,0.12"
  operator_color: Color = c"#0550ae"
  comment_color: Color = c"0.3059,0.5412,0.3608"
  string_color: Color = c"0.6980,0.2549,0.2157"
}

record CodeHighlightTheme {
  code: CodeStyle = CodeStyle {}
  fill: Color? = none
  stroke: Color? = none
}

record ChromeStyle {
  fill: Color? = none
  stroke: Color? = none
  line_width: Number = 1
  radius: Number = 10
  pad_x: Number = 0
  pad_y: Number = 0
}

record UnderlineStyle {
  color: Color? = none
  width: Number = 1
  offset: Number = -2
}

record RuleStyle {
  stroke: Color? = none
  line_width: Number = 1
  dash: String = ""
}

record AssetStyle {
  scale: Number = 1
  width: Number? = none
}

type Doc = object {
  layout_v: LayoutPolicy = LayoutPolicy.top_flow
  layout_v_center_offset: Number = 0
  background_fill: Color? = none
  pageno_fmt: String? = none
  footer_text: String? = none
  logo_path: String? = none
  logo_scale: Number = 1
  watermark: String? = none
  math_align: Align = Align.center
  code_theme_plain_color: Color? = none
  code_theme_keyword_color: Color? = none
  code_theme_function_color: Color? = none
  code_theme_type_color: Color? = none
  code_theme_constant_color: Color? = none
  code_theme_number_color: Color? = none
  code_theme_variable_color: Color? = none
  code_theme_operator_color: Color? = none
  code_theme_comment_color: Color? = none
  code_theme_string_color: Color? = none
  code_theme_fill: Color? = none
  code_theme_stroke: Color? = none
}

type PageContext = object {
  base = Doc
}

type Flow = object {
  render_kind: RenderKind = RenderKind.text
  text_parse: TextParseMode = TextParseMode.none
  layout: LayoutStyle
  wrap: WrapMode = WrapMode.on
  layout_font_size: Number? = none
  layout_line_height: Number? = none
  layout_spacing_after: Number = 32
  layout_x: Number = 96
  layout_right_inset: Number = 96
  fit: FitPolicy = FitPolicy.warn
  link_id: String = ""
  numbered_item_source: String? = none
  numbered_item_number: String? = none
  numbered_item_format: String? = none
}

type Text = object {
  base = Flow

  text: TextStyle
  underline: UnderlineStyle
  text_parse: TextParseMode = TextParseMode.inline
  text_font_family: String = "Helvetica"
  text_font_weight: Number = 400
  text_font_style: FontStyle = FontStyle.normal
  text_font_stretch: FontStretch = FontStretch.normal
  text_markdown_bold_weight: Number = 700
  text_markdown_italic_style: FontStyle = FontStyle.italic
  text_code_font_family: String = "Courier"
  text_code_font_weight: Number = 400
  text_code_font_style: FontStyle = FontStyle.normal
  text_code_font_stretch: FontStretch = FontStretch.normal
  text_size: Number = 20
  text_line_height: Number? = none
  text_color: Color = c"0.08,0.08,0.08"
  text_link_color: Color = c"0.1,0.25,0.75"
  text_markdown_bold_color: Color? = none
  text_link_underline_width: Number = 0.8
  text_link_underline_offset: Number = -1.5
  text_inline_math_height_factor: Number = 1.02
  text_inline_math_spacing: Number = 0.08
  text_display_math_height_factor: Number = 2
  math_align: Align = Align.center
  text_emoji_spacing: Number = 0.12
  text_markdown_block_gap: Number = 8
  text_markdown_list_inset: Number = 8
  text_markdown_list_indent: Number = 26
  text_markdown_code_font_size: Number = 15
  text_markdown_code_line_height: Number = 20
  text_markdown_code_pad_x: Number = 12
  text_markdown_code_pad_y: Number = 10
  text_markdown_code_fill: Color? = none
  text_markdown_code_stroke: Color? = none
  text_markdown_code_line_width: Number = 1
  text_markdown_code_radius: Number = 10
  text_markdown_code_plain_color: Color? = none
  text_markdown_code_keyword_color: Color? = none
  text_markdown_code_function_color: Color? = none
  text_markdown_code_type_color: Color? = none
  text_markdown_code_constant_color: Color? = none
  text_markdown_code_number_color: Color? = none
  text_markdown_code_variable_color: Color? = none
  text_markdown_code_operator_color: Color? = none
  text_markdown_code_comment_color: Color? = none
  text_markdown_code_string_color: Color? = none
  text_markdown_table_cell_pad_x: Number = 10
  text_markdown_table_cell_pad_y: Number = 7
  text_markdown_table_border: Color = c"0.82,0.84,0.88"
  text_markdown_table_line_width: Number = 0.8
  text_markdown_table_header_fill: Color = c"0.94,0.96,0.98"
  text_markdown_table_alt_row_fill: Color? = none
  text_cjk_bold_passes: Number = 1
  text_cjk_bold_dx: Number = 0.05
  underline_color: Color? = none
  underline_width: Number = 1
  underline_offset: Number = -2
}

type Title = object {
  base = Text
  roles = ["title"]

  text_size: Number = 34
  text_line_height: Number? = none
  text_color: Color = c"0,0,0.0353"
  layout_font_size: Number? = none
  layout_line_height: Number? = none
  layout_spacing_after: Number = 58
  layout_x: Number = 72
  layout_right_inset: Number = 72
}

type Sub = object {
  base = Text
  roles = ["subtitle"]

  text_size: Number = 18
  text_line_height: Number? = none
  text_color: Color = c"0,0,0.0353"
  layout_font_size: Number? = none
  layout_line_height: Number? = none
  layout_spacing_after: Number = 38
  layout_x: Number = 96
  layout_right_inset: Number = 96
}

type Body = object {
  base = Text
  roles = ["body"]

  text_parse: TextParseMode = TextParseMode.block
  text_size: Number = 20
  text_line_height: Number? = none
  text_color: Color = c"0,0,0.0353"
  layout_font_size: Number? = none
  layout_line_height: Number? = none
  layout_spacing_after: Number = 32
  layout_x: Number = 96
  layout_right_inset: Number = 96
}

type Note = object {
  base = Body
  roles = ["note"]

  layout_spacing_after: Number = 28
}

type By = object {
  base = Text
  roles = ["byline"]

  text_size: Number = 20
  text_line_height: Number? = none
  text_color: Color = c"0.2745,0.5098,0.7059"
  layout_font_size: Number? = none
  layout_line_height: Number? = none
  layout_spacing_after: Number = 18
  layout_x: Number = 72
  layout_right_inset: Number = 72
}

type Lab = object {
  base = Text
  roles = ["label"]

  text_size: Number = 14
  text_line_height: Number? = none
  text_color: Color = c"0.2745,0.5098,0.7059"
  layout_font_size: Number? = none
  layout_line_height: Number? = none
  layout_spacing_after: Number = 0
  layout_x: Number = 72
  layout_right_inset: Number = 72
  wrap: WrapMode = WrapMode.off
}

type Cite = object {
  base = Text
  roles = ["citation"]

  text_parse: TextParseMode = TextParseMode.inline
  text_size: Number = 13
  text_line_height: Number? = none
  text_color: Color = c"0.58,0.58,0.58"
  text_link_color: Color = c"0.58,0.58,0.58"
  layout_font_size: Number? = none
  layout_line_height: Number? = none
  layout_spacing_after: Number = 0
  layout_x: Number = 120
  layout_right_inset: Number = 90
  wrap: WrapMode = WrapMode.off
}

type Code = object {
  base = Text
  roles = ["code"]

  code: CodeStyle
  render_kind: RenderKind = RenderKind.code
  text_parse: TextParseMode = TextParseMode.none
  text_font_family: String = "Courier"
  text_code_font_family: String = "Courier"
  text_size: Number = 15
  text_line_height: Number? = none
  text_color: Color = c"0.12,0.12,0.12"
  layout_font_size: Number? = none
  layout_line_height: Number? = none
  layout_spacing_after: Number = 32
  layout_x: Number = 102
  layout_right_inset: Number = 102
  wrap: WrapMode = WrapMode.off
  language: String = "plain"
  code_plain_color: Color = c"0.12,0.12,0.12"
  code_keyword_color: Color = c"#cf222e"
  code_function_color: Color = c"#8250df"
  code_type_color: Color = c"#953800"
  code_constant_color: Color = c"#0550ae"
  code_number_color: Color = c"#0550ae"
  code_variable_color: Color = c"0.12,0.12,0.12"
  code_operator_color: Color = c"#0550ae"
  code_comment_color: Color = c"0.3059,0.5412,0.3608"
  code_string_color: Color = c"0.6980,0.2549,0.2157"
}

type Math = object {
  base = Text
  roles = ["math"]

  math: MathStyle
  render_kind: RenderKind = RenderKind.vector_math
  text_parse: TextParseMode = TextParseMode.none
  text_font_family: String = "Courier"
  text_size: Number = 18
  text_line_height: Number? = none
  text_color: Color = c"0,0,0.0353"
  layout_font_size: Number? = none
  layout_line_height: Number? = none
  layout_spacing_after: Number = 32
  layout_x: Number = 102
  layout_right_inset: Number = 102
  wrap: WrapMode = WrapMode.off
  math_scale: Number = 1
  math_block_line_height: Number = 22
  math_block_min_height: Number = 30
  math_block_vertical_padding: Number = 2
}

type Tex = object {
  base = Math
  roles = ["math_tex"]

}

type Fig = object {
  base = Text
  roles = ["figure"]

  asset: AssetStyle
  text_font_family: String = "Courier"
  text_size: Number = 16
  text_line_height: Number? = none
  text_color: Color = c"0.18,0.18,0.18"
  layout_font_size: Number? = none
  layout_line_height: Number? = none
  layout_spacing_after: Number = 32
  layout_x: Number = 102
  layout_right_inset: Number = 102
  wrap: WrapMode = WrapMode.off
  asset_scale: Number = 1
}

type Img = object {
  base = Fig
  roles = ["image"]

  render_kind: RenderKind = RenderKind.raster_asset
  text_parse: TextParseMode = TextParseMode.none
}

type Pdf = object {
  base = Fig
  roles = ["pdf"]

  render_kind: RenderKind = RenderKind.vector_asset
  text_parse: TextParseMode = TextParseMode.none
}

type Panel = object {
  base = Flow
  roles = ["panel"]

  chrome: ChromeStyle
  render_kind: RenderKind = RenderKind.chrome_only
  layout_font_size: Number = 4
  layout_line_height: Number = 4
  layout_spacing_after: Number = 0
  layout_x: Number = 72
  layout_right_inset: Number = 72
  wrap: WrapMode = WrapMode.off
  chrome_fill: Color? = none
  chrome_stroke: Color? = none
  chrome_line_width: Number = 1
  chrome_radius: Number = 10
  chrome_pad_x: Number = 0
  chrome_pad_y: Number = 0
}

type Rule = object {
  base = Panel
  roles = ["rule"]

  rule: RuleStyle
  layout_spacing_after: Number = 24
  rule_stroke: Color? = c"#d0d7de"
  rule_line_width: Number = 1
  rule_dash: String = ""
}

type Pageno = object {
  base = Text
  roles = ["pageno"]

  pageno_format: String? = none
  text_size: Number = 11
  text_line_height: Number? = none
  layout_font_size: Number? = none
  layout_line_height: Number? = none
  layout_spacing_after: Number = 0
  wrap: WrapMode = WrapMode.off
}

type Footer = object {
  base = Text
  roles = ["footer"]

  text_size: Number = 12
  text_line_height: Number? = none
  text_color: Color = c"0.42,0.42,0.42"
  layout_font_size: Number? = none
  layout_line_height: Number? = none
  layout_spacing_after: Number = 0
  wrap: WrapMode = WrapMode.off
}

type Logo = object {
  base = Img
  roles = ["logo"]

  asset_scale: Number = 1
  wrap: WrapMode = WrapMode.off
}

type Watermark = object {
  base = Text
  roles = ["watermark"]

  text_size: Number = 72
  text_line_height: Number? = none
  text_color: Color = c"0.85,0.85,0.85"
  layout_font_size: Number? = none
  layout_line_height: Number? = none
  layout_spacing_after: Number = 0
  wrap: WrapMode = WrapMode.off
}

type Toc = object {
  base = Body
  roles = ["toc"]
}

type Group = object {
  base = Flow
  roles = ["group"]

  render_kind: RenderKind = RenderKind.chrome_only
  layout_font_size: Number = 4
  layout_line_height: Number = 4
  layout_spacing_after: Number = 0
  layout_x: Number = 72
  layout_right_inset: Number = 72
  wrap: WrapMode = WrapMode.off
}
