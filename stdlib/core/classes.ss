type LayoutPolicy = "top" | "top_flow" | "center" | "center_stack"
type RenderKind = "text" | "code" | "vector_math" | "vector_asset" | "raster_asset" | "chrome" | "chrome_only"
type TextParseMode = "none" | "inline" | "block"
type WrapMode = "on" | "off"
type FitPolicy = "warn" | "error" | "ignore"
type Color = string @refine(color)
type ScalarLike = string | number

type DocumentObject = object {
  layout_v: LayoutPolicy = "top_flow"
  layout_v_center_offset: ScalarLike = "0"
  background_fill: Color = ""
  page_numbers_enabled: string = ""
  page_numbers_format: string = ""
  running_footer_text: string = ""
  document_logo_path: string = ""
  document_logo_scale: ScalarLike = "1"
  watermark_text: string = ""
  require_titles_enabled: string = ""
}

type PageObject = object {
  base = DocumentObject
}

type FlowObject = object {
  render_kind: RenderKind = "text"
  text_parse: TextParseMode = "none"
  wrap: WrapMode = "on"
  layout_font_size: ScalarLike = "20"
  layout_line_height: ScalarLike = "28"
  layout_spacing_after: ScalarLike = "28"
  layout_x: ScalarLike = "96"
  layout_right_inset: ScalarLike = "96"
  style: string = "default"
  fit: FitPolicy = "warn"
  link_id: string = ""
}

type TextObject = object {
  base = FlowObject

  text_parse: TextParseMode = "inline"
  text_font: string = "Helvetica"
  text_bold_font: string = "Helvetica-Bold"
  text_italic_font: string = "Helvetica-Oblique"
  text_code_font: string = "Courier"
  text_size: ScalarLike = "20"
  text_line_height: ScalarLike = "28"
  text_color: Color = c"0.08,0.08,0.08"
  text_link_color: Color = c"0.1,0.25,0.75"
  text_link_underline_width: ScalarLike = "0.8"
  text_link_underline_offset: ScalarLike = "-1.5"
  text_inline_math_height_factor: ScalarLike = "1.02"
  text_inline_math_spacing: ScalarLike = "0.08"
  text_markdown_block_gap: ScalarLike = "4"
  text_markdown_list_inset: ScalarLike = "8"
  text_markdown_list_indent: ScalarLike = "26"
  text_markdown_code_font_size: ScalarLike = "15"
  text_markdown_code_line_height: ScalarLike = "20"
  text_markdown_code_pad_x: ScalarLike = "12"
  text_markdown_code_pad_y: ScalarLike = "10"
  text_markdown_code_fill: Color = ""
  text_markdown_code_stroke: Color = ""
  text_markdown_code_line_width: ScalarLike = "1"
  text_markdown_code_radius: ScalarLike = "10"
  text_markdown_table_cell_pad_x: ScalarLike = "10"
  text_markdown_table_cell_pad_y: ScalarLike = "7"
  text_markdown_table_border: Color = c"0.82,0.84,0.88"
  text_markdown_table_line_width: ScalarLike = "0.8"
  text_markdown_table_header_fill: Color = c"0.94,0.96,0.98"
  text_markdown_table_alt_row_fill: Color = ""
  text_cjk_bold_passes: ScalarLike = "1"
  text_cjk_bold_dx: ScalarLike = "0.05"
  underline_color: Color = ""
  underline_width: ScalarLike = "1"
  underline_offset: ScalarLike = "-2"
}

type TitleObject = object {
  base = TextObject
  roles = ["title"]

  text_size: ScalarLike = "34"
  text_line_height: ScalarLike = "40"
  text_color: Color = c"0,0,0.0353"
  layout_font_size: ScalarLike = "34"
  layout_line_height: ScalarLike = "40"
  layout_spacing_after: ScalarLike = "54"
  layout_x: ScalarLike = "72"
  layout_right_inset: ScalarLike = "72"
}

type SubtitleObject = object {
  base = TextObject
  roles = ["subtitle"]

  text_size: ScalarLike = "18"
  text_line_height: ScalarLike = "24"
  text_color: Color = c"0,0,0.0353"
  layout_font_size: ScalarLike = "18"
  layout_line_height: ScalarLike = "24"
  layout_spacing_after: ScalarLike = "34"
  layout_x: ScalarLike = "96"
  layout_right_inset: ScalarLike = "96"
}

type BodyObject = object {
  base = TextObject
  roles = ["body"]

  text_parse: TextParseMode = "block"
  text_size: ScalarLike = "20"
  text_line_height: ScalarLike = "28"
  text_color: Color = c"0,0,0.0353"
  layout_font_size: ScalarLike = "20"
  layout_line_height: ScalarLike = "28"
  layout_spacing_after: ScalarLike = "28"
  layout_x: ScalarLike = "96"
  layout_right_inset: ScalarLike = "96"
}

type NoteObject = object {
  base = BodyObject
  roles = ["note"]

  layout_spacing_after: ScalarLike = "24"
}

type BylineObject = object {
  base = TextObject
  roles = ["byline"]

  text_size: ScalarLike = "20"
  text_line_height: ScalarLike = "26"
  text_color: Color = c"0.2745,0.5098,0.7059"
  layout_font_size: ScalarLike = "20"
  layout_line_height: ScalarLike = "26"
  layout_spacing_after: ScalarLike = "18"
  layout_x: ScalarLike = "72"
  layout_right_inset: ScalarLike = "72"
}

type LabelObject = object {
  base = TextObject
  roles = ["label"]

  text_size: ScalarLike = "14"
  text_line_height: ScalarLike = "18"
  text_color: Color = c"0.2745,0.5098,0.7059"
  layout_font_size: ScalarLike = "14"
  layout_line_height: ScalarLike = "18"
  layout_spacing_after: ScalarLike = "0"
  layout_x: ScalarLike = "72"
  layout_right_inset: ScalarLike = "72"
  wrap: WrapMode = "off"
}

type CitationObject = object {
  base = TextObject
  roles = ["citation"]

  text_parse: TextParseMode = "inline"
  text_size: ScalarLike = "13"
  text_line_height: ScalarLike = "17"
  text_color: Color = c"0.58,0.58,0.58"
  text_link_color: Color = c"0.58,0.58,0.58"
  layout_font_size: ScalarLike = "13"
  layout_line_height: ScalarLike = "17"
  layout_spacing_after: ScalarLike = "0"
  layout_x: ScalarLike = "120"
  layout_right_inset: ScalarLike = "90"
  wrap: WrapMode = "off"
}

type CodeObject = object {
  base = TextObject
  roles = ["code"]

  render_kind: RenderKind = "code"
  text_parse: TextParseMode = "none"
  text_font: string = "Courier"
  text_size: ScalarLike = "15"
  text_line_height: ScalarLike = "20"
  text_color: Color = c"0.12,0.12,0.12"
  layout_font_size: ScalarLike = "15"
  layout_line_height: ScalarLike = "20"
  layout_spacing_after: ScalarLike = "28"
  layout_x: ScalarLike = "102"
  layout_right_inset: ScalarLike = "102"
  wrap: WrapMode = "off"
  language: string = "plain"
  code_plain_color: Color = c"0.12,0.12,0.12"
  code_keyword_color: Color = c"0.1725,0.3451,0.7882"
  code_comment_color: Color = c"0.3059,0.5412,0.3608"
  code_string_color: Color = c"0.6980,0.2549,0.2157"
}

type MathObject = object {
  base = TextObject
  roles = ["math"]

  text_font: string = "Courier"
  text_size: ScalarLike = "18"
  text_line_height: ScalarLike = "24"
  text_color: Color = c"0,0,0.0353"
  layout_font_size: ScalarLike = "18"
  layout_line_height: ScalarLike = "24"
  layout_spacing_after: ScalarLike = "28"
  layout_x: ScalarLike = "102"
  layout_right_inset: ScalarLike = "102"
  wrap: WrapMode = "off"
  math_scale: ScalarLike = "1"
  math_block_line_height: ScalarLike = "22"
  math_block_min_height: ScalarLike = "30"
  math_block_vertical_padding: ScalarLike = "2"
}

type MathTexObject = object {
  base = MathObject
  roles = ["math_tex"]

  render_kind: RenderKind = "vector_math"
  text_parse: TextParseMode = "none"
}

type FigureObject = object {
  base = TextObject
  roles = ["figure"]

  text_font: string = "Courier"
  text_size: ScalarLike = "16"
  text_line_height: ScalarLike = "20"
  text_color: Color = c"0.18,0.18,0.18"
  layout_font_size: ScalarLike = "16"
  layout_line_height: ScalarLike = "20"
  layout_spacing_after: ScalarLike = "28"
  layout_x: ScalarLike = "102"
  layout_right_inset: ScalarLike = "102"
  wrap: WrapMode = "off"
  asset_scale: ScalarLike = "1"
}

type ImageObject = object {
  base = FigureObject
  roles = ["image"]

  render_kind: RenderKind = "raster_asset"
  text_parse: TextParseMode = "none"
}

type PdfObject = object {
  base = FigureObject
  roles = ["pdf"]

  render_kind: RenderKind = "vector_asset"
  text_parse: TextParseMode = "none"
}

type PanelObject = object {
  base = FlowObject
  roles = ["panel"]

  render_kind: RenderKind = "chrome"
  layout_font_size: ScalarLike = "4"
  layout_line_height: ScalarLike = "4"
  layout_spacing_after: ScalarLike = "0"
  layout_x: ScalarLike = "72"
  layout_right_inset: ScalarLike = "72"
  wrap: WrapMode = "off"
  chrome_fill: Color = ""
  chrome_stroke: Color = ""
  chrome_line_width: ScalarLike = "1"
  chrome_radius: ScalarLike = "10"
  chrome_pad_x: ScalarLike = "0"
  chrome_pad_y: ScalarLike = "0"
}

type RuleObject = object {
  base = PanelObject
  roles = ["rule"]

  rule_stroke: Color = ""
  rule_line_width: ScalarLike = "1"
  rule_dash: string = ""
}

type PageNumberObject = object {
  base = TextObject
  roles = ["page_number"]

  text_size: ScalarLike = "11"
  text_line_height: ScalarLike = "14"
  layout_font_size: ScalarLike = "11"
  layout_line_height: ScalarLike = "14"
  layout_spacing_after: ScalarLike = "0"
  wrap: WrapMode = "off"
}

type RunningFooterObject = object {
  base = TextObject
  roles = ["running_footer"]

  text_size: ScalarLike = "12"
  text_line_height: ScalarLike = "15"
  text_color: Color = c"0.42,0.42,0.42"
  layout_font_size: ScalarLike = "12"
  layout_line_height: ScalarLike = "15"
  layout_spacing_after: ScalarLike = "0"
  wrap: WrapMode = "off"
}

type DocumentLogoObject = object {
  base = ImageObject
  roles = ["document_logo"]

  asset_scale: ScalarLike = "1"
  wrap: WrapMode = "off"
}

type WatermarkObject = object {
  base = TextObject
  roles = ["watermark"]

  text_size: ScalarLike = "72"
  text_line_height: ScalarLike = "80"
  text_color: Color = c"0.85,0.85,0.85"
  layout_font_size: ScalarLike = "72"
  layout_line_height: ScalarLike = "80"
  layout_spacing_after: ScalarLike = "0"
  wrap: WrapMode = "off"
}

type TocObject = object {
  base = BodyObject
  roles = ["toc"]
}

type GroupObject = object {
  base = FlowObject
  roles = ["group"]

  render_kind: RenderKind = "chrome_only"
  layout_font_size: ScalarLike = "4"
  layout_line_height: ScalarLike = "4"
  layout_spacing_after: ScalarLike = "0"
  layout_x: ScalarLike = "72"
  layout_right_inset: ScalarLike = "72"
  wrap: WrapMode = "off"
}
