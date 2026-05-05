type LayoutPolicy = "top" | "top_flow" | "center" | "center_stack"
type RenderKind = "text" | "code" | "vector_math" | "vector_asset" | "raster_asset" | "chrome" | "chrome_only"
type WrapMode = "on" | "off"
type FitPolicy = "warn" | "error" | "ignore"
type Color = string @refine(color)
type ScalarLike = string | number

type DocumentObject = object {
  layout_v: LayoutPolicy = "top_flow"
}

type PageObject = object {
  base = DocumentObject
}

type FlowObject = object {
  render_kind: RenderKind = "text"
  wrap: WrapMode = "on"
  layout_font_size: ScalarLike = "20"
  layout_line_height: ScalarLike = "28"
  layout_spacing_after: ScalarLike = "28"
  layout_x: ScalarLike = "96"
  layout_right_inset: ScalarLike = "96"
  style: string = "default"
  fit: FitPolicy = "warn"
}

type TextObject = object {
  base = FlowObject
  roles = ["title", "subtitle", "body", "note", "byline", "label"]

  text_font: string = "Helvetica"
  text_bold_font: string = "Helvetica-Bold"
  text_italic_font: string = "Helvetica-Oblique"
  text_code_font: string = "Courier"
  text_size: ScalarLike = "20"
  text_line_height: ScalarLike = "28"
  text_color: Color = "0.08,0.08,0.08"
  text_link_color: Color = "0.1,0.25,0.75"
  text_link_underline_width: ScalarLike = "0.8"
  text_link_underline_offset: ScalarLike = "-1.5"
  text_inline_math_height_factor: ScalarLike = "1.02"
  text_inline_math_spacing: ScalarLike = "0.08"
  text_markdown_block_gap: ScalarLike = "4"
  text_markdown_list_indent: ScalarLike = "26"
  text_markdown_code_font_size: ScalarLike = "15"
  text_markdown_code_line_height: ScalarLike = "20"
  text_markdown_code_pad_x: ScalarLike = "12"
  text_markdown_code_pad_y: ScalarLike = "10"
  text_markdown_code_fill: Color = "0.95,0.95,0.95"
  text_markdown_code_stroke: Color = "0.85,0.85,0.85"
  text_markdown_code_line_width: ScalarLike = "1"
  text_markdown_code_radius: ScalarLike = "10"
  text_cjk_bold_passes: ScalarLike = "1"
  text_cjk_bold_dx: ScalarLike = "0.05"
  underline_color: Color = "0.1,0.25,0.75"
  underline_width: ScalarLike = "1"
  underline_offset: ScalarLike = "-2"
}

type CodeObject = object {
  base = TextObject
  roles = ["code"]

  language: string = "plain"
  code_plain_color: Color = "0.12,0.12,0.12"
  code_keyword_color: Color = "0.1725,0.3451,0.7882"
  code_comment_color: Color = "0.3059,0.5412,0.3608"
  code_string_color: Color = "0.6980,0.2549,0.2157"
}

type MathObject = object {
  base = TextObject
  roles = ["math"]

  math_scale: ScalarLike = "1"
}

type FigureObject = object {
  base = TextObject
  roles = ["figure"]

  asset_scale: ScalarLike = "1"
}

type PanelObject = object {
  base = FlowObject
  roles = ["panel"]

  chrome_fill: Color = "1,1,1"
  chrome_stroke: Color = "0,0,0"
  chrome_line_width: ScalarLike = "1"
  chrome_radius: ScalarLike = "10"
}

type RuleObject = object {
  base = PanelObject
  roles = ["rule"]

  rule_stroke: Color = "0,0,0"
  rule_line_width: ScalarLike = "1"
  rule_dash: string = ""
}

type PageNumberObject = object {
  base = TextObject
  roles = ["page_number"]
}

type TocObject = object {
  base = TextObject
  roles = ["toc"]
}

type GroupObject = object {
  base = FlowObject
  roles = ["group"]
}
