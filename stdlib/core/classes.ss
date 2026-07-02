type LayoutPolicy = top | top_flow | center | center_stack
type RenderKind = text | code | vector_math | vector_asset | raster_asset | shape | chrome_only
type ShapeMarker = plain | arrow
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

record ShapeStyle {
  stroke: Color? = c"#d0d7de"
  line_width: Number = 1
  dash: String = ""
  start_x: Number = 0
  start_y: Number = 0
  end_x: Number = 1
  end_y: Number = 1
  marker_start: ShapeMarker = ShapeMarker.plain
  marker_end: ShapeMarker = ShapeMarker.plain
  marker_size: Number = 10
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
  layout: LayoutStyle = LayoutStyle {}
  link_id: String = ""
  numbered_item_source: String? = none
  numbered_item_number: String? = none
  numbered_item_format: String? = none
}

type Text = object {
  base = Flow

  text: TextStyle = TextStyle {}
  code: CodeStyle = CodeStyle {}
  underline: UnderlineStyle = UnderlineStyle {}
  math_align: Align = Align.center
}

type Title = object {
  base = Text
  roles = ["title"]

  text: TextStyle = TextStyle {
    size = 34
    color = c"0,0,0.0353"
  }
  layout: LayoutStyle = LayoutStyle {
    spacing_after = 58
    x = 72
    right_inset = 72
  }
}

type Sub = object {
  base = Text
  roles = ["subtitle"]

  text: TextStyle = TextStyle {
    size = 18
    color = c"0,0,0.0353"
  }
  layout: LayoutStyle = LayoutStyle {
    spacing_after = 38
    x = 96
    right_inset = 96
  }
}

type Body = object {
  base = Text
  roles = ["body"]

  text: TextStyle = TextStyle {
    parse = TextParseMode.block
    size = 20
    color = c"0,0,0.0353"
  }
  layout: LayoutStyle = LayoutStyle {
    spacing_after = 32
    x = 96
    right_inset = 96
  }
}

type Note = object {
  base = Body
  roles = ["note"]

  layout: LayoutStyle = LayoutStyle {
    spacing_after = 28
    x = 96
    right_inset = 96
  }
}

type By = object {
  base = Text
  roles = ["byline"]

  text: TextStyle = TextStyle {
    size = 20
    color = c"0.2745,0.5098,0.7059"
  }
  layout: LayoutStyle = LayoutStyle {
    spacing_after = 18
    x = 72
    right_inset = 72
  }
}

type Lab = object {
  base = Text
  roles = ["label"]

  text: TextStyle = TextStyle {
    size = 14
    color = c"0.2745,0.5098,0.7059"
  }
  layout: LayoutStyle = LayoutStyle {
    spacing_after = 0
    x = 72
    right_inset = 72
    wrap = WrapMode.off
  }
}

type Cite = object {
  base = Text
  roles = ["citation"]

  text: TextStyle = TextStyle {
    parse = TextParseMode.inline
    size = 13
    color = c"0.58,0.58,0.58"
    link_color = c"0.58,0.58,0.58"
  }
  layout: LayoutStyle = LayoutStyle {
    spacing_after = 0
    x = 120
    right_inset = 90
    wrap = WrapMode.off
  }
}

type Code = object {
  base = Text
  roles = ["code"]

  render_kind: RenderKind = RenderKind.code
  text: TextStyle = TextStyle {
    parse = TextParseMode.none
    font = FontFace { family = "Courier" }
    code_font = FontFace { family = "Courier" }
    size = 15
    color = c"0.12,0.12,0.12"
  }
  layout: LayoutStyle = LayoutStyle {
    spacing_after = 32
    x = 102
    right_inset = 102
    wrap = WrapMode.off
  }
  language: String = "plain"
  code: CodeStyle = CodeStyle {
    plain_color = c"0.12,0.12,0.12"
    keyword_color = c"#cf222e"
    function_color = c"#8250df"
    type_color = c"#953800"
    constant_color = c"#0550ae"
    number_color = c"#0550ae"
    variable_color = c"0.12,0.12,0.12"
    operator_color = c"#0550ae"
    comment_color = c"0.3059,0.5412,0.3608"
    string_color = c"0.6980,0.2549,0.2157"
  }
}

type Math = object {
  base = Text
  roles = ["math"]

  math: MathStyle = MathStyle {}
  render_kind: RenderKind = RenderKind.vector_math
  text: TextStyle = TextStyle {
    parse = TextParseMode.none
    font = FontFace { family = "Courier" }
    size = 18
    color = c"0,0,0.0353"
  }
  layout: LayoutStyle = LayoutStyle {
    spacing_after = 32
    x = 102
    right_inset = 102
    wrap = WrapMode.off
  }
}

type Tex = object {
  base = Math
  roles = ["math_tex"]

}

type Fig = object {
  base = Text
  roles = ["figure"]

  asset: AssetStyle = AssetStyle {}
  text: TextStyle = TextStyle {
    font = FontFace { family = "Courier" }
    size = 16
    color = c"0.18,0.18,0.18"
  }
  layout: LayoutStyle = LayoutStyle {
    spacing_after = 32
    x = 102
    right_inset = 102
    wrap = WrapMode.off
  }
}

type Img = object {
  base = Fig
  roles = ["image"]

  render_kind: RenderKind = RenderKind.raster_asset
  text: TextStyle = TextStyle {
    parse = TextParseMode.none
    font = FontFace { family = "Courier" }
    size = 16
    color = c"0.18,0.18,0.18"
  }
}

type Pdf = object {
  base = Fig
  roles = ["pdf"]

  render_kind: RenderKind = RenderKind.vector_asset
  text: TextStyle = TextStyle {
    parse = TextParseMode.none
    font = FontFace { family = "Courier" }
    size = 16
    color = c"0.18,0.18,0.18"
  }
}

type Panel = object {
  base = Flow
  roles = ["panel"]

  chrome: ChromeStyle = ChromeStyle {}
  render_kind: RenderKind = RenderKind.chrome_only
  layout: LayoutStyle = LayoutStyle {
    font_size = 4
    line_height = 4
    spacing_after = 0
    x = 72
    right_inset = 72
    wrap = WrapMode.off
  }
}

type Rule = object {
  base = Panel
  roles = ["rule"]

  rule: RuleStyle = RuleStyle {
    stroke = c"#d0d7de"
  }
  layout: LayoutStyle = LayoutStyle {
    font_size = 4
    line_height = 4
    spacing_after = 24
    x = 72
    right_inset = 72
    wrap = WrapMode.off
  }
}

type Shape = object {
  base = Panel
  roles = ["shape"]

  shape: ShapeStyle = ShapeStyle {}
  render_kind: RenderKind = RenderKind.shape
  chrome: ChromeStyle = ChromeStyle {}
  layout: LayoutStyle = LayoutStyle {
    font_size = 1
    line_height = 1
    spacing_after = 0
    x = 72
    right_inset = 72
    wrap = WrapMode.off
  }
}

type Pageno = object {
  base = Text
  roles = ["pageno"]

  pageno_format: String? = none
  text: TextStyle = TextStyle {
    size = 11
  }
  layout: LayoutStyle = LayoutStyle {
    spacing_after = 0
    wrap = WrapMode.off
  }
}

type Footer = object {
  base = Text
  roles = ["footer"]

  text: TextStyle = TextStyle {
    size = 12
    color = c"0.42,0.42,0.42"
  }
  layout: LayoutStyle = LayoutStyle {
    spacing_after = 0
    wrap = WrapMode.off
  }
}

type Logo = object {
  base = Img
  roles = ["logo"]

  asset: AssetStyle = AssetStyle {}
  layout: LayoutStyle = LayoutStyle {
    spacing_after = 32
    x = 102
    right_inset = 102
    wrap = WrapMode.off
  }
}

type Watermark = object {
  base = Text
  roles = ["watermark"]

  text: TextStyle = TextStyle {
    size = 72
    color = c"0.85,0.85,0.85"
  }
  layout: LayoutStyle = LayoutStyle {
    spacing_after = 0
    wrap = WrapMode.off
  }
}

type Toc = object {
  base = Body
  roles = ["toc"]
}

type Group = object {
  base = Flow
  roles = ["group"]

  render_kind: RenderKind = RenderKind.chrome_only
  layout: LayoutStyle = LayoutStyle {
    font_size = 4
    line_height = 4
    spacing_after = 0
    x = 72
    right_inset = 72
    wrap = WrapMode.off
  }
}
