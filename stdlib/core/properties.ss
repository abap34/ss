type LayoutPolicy = "top" | "top_flow" | "center" | "center_stack"
type RenderKind = "text" | "code" | "vector_math" | "vector_asset" | "raster_asset" | "chrome" | "chrome_only"
type WrapMode = "on" | "off"
type FitPolicy = "warn" | "error" | "ignore"
type Color = string
type ScalarLike = string | number

property layout_v: LayoutPolicy {
  target: document | page
}

property render_kind: RenderKind {
  target: any
}

property wrap: WrapMode {
  target: any
}

property layout_font_size: ScalarLike {
  target: any
}

property layout_line_height: ScalarLike {
  target: any
}

property layout_spacing_after: ScalarLike {
  target: any
}

property layout_x: ScalarLike {
  target: any
}

property layout_right_inset: ScalarLike {
  target: any
}

property style: string {
  target: any
}

property fit: FitPolicy {
  target: any
}

property text_font: string {
  target: text | code | math | figure | page_number | toc
}

property text_bold_font: string {
  target: text | code | math | figure | page_number | toc
}

property text_italic_font: string {
  target: text | code | math | figure | page_number | toc
}

property text_code_font: string {
  target: text | code | math | figure | page_number | toc
}

property text_size: ScalarLike {
  target: text | code | math | figure | page_number | toc
}

property text_line_height: ScalarLike {
  target: text | code | math | figure | page_number | toc
}

property text_color: Color {
  target: text | code | math | figure | page_number | toc
}

property text_link_color: Color {
  target: text | code | math | figure | page_number | toc
}

property text_link_underline_width: ScalarLike {
  target: text | code | math | figure | page_number | toc
}

property text_link_underline_offset: ScalarLike {
  target: text | code | math | figure | page_number | toc
}

property text_inline_math_height_factor: ScalarLike {
  target: text | code | math | figure | page_number | toc
}

property text_inline_math_spacing: ScalarLike {
  target: text | code | math | figure | page_number | toc
}

property text_markdown_block_gap: ScalarLike {
  target: text | code | math | figure | page_number | toc
}

property text_markdown_list_indent: ScalarLike {
  target: text | code | math | figure | page_number | toc
}

property text_markdown_code_font_size: ScalarLike {
  target: text | code | math | figure | page_number | toc
}

property text_markdown_code_line_height: ScalarLike {
  target: text | code | math | figure | page_number | toc
}

property text_markdown_code_pad_x: ScalarLike {
  target: text | code | math | figure | page_number | toc
}

property text_markdown_code_pad_y: ScalarLike {
  target: text | code | math | figure | page_number | toc
}

property text_markdown_code_fill: Color {
  target: text | code | math | figure | page_number | toc
}

property text_markdown_code_stroke: Color {
  target: text | code | math | figure | page_number | toc
}

property text_markdown_code_line_width: ScalarLike {
  target: text | code | math | figure | page_number | toc
}

property text_markdown_code_radius: ScalarLike {
  target: text | code | math | figure | page_number | toc
}

property text_cjk_bold_passes: ScalarLike {
  target: text | code | math | figure | page_number | toc
}

property text_cjk_bold_dx: ScalarLike {
  target: text | code | math | figure | page_number | toc
}

property language: string {
  target: text | code | math | figure | page_number | toc
}

property underline_color: Color {
  target: text | code | math | figure | page_number | toc
}

property underline_width: ScalarLike {
  target: text | code | math | figure | page_number | toc
}

property underline_offset: ScalarLike {
  target: text | code | math | figure | page_number | toc
}

property code_plain_color: Color {
  target: text | code | math | figure | page_number | toc
}

property code_keyword_color: Color {
  target: text | code | math | figure | page_number | toc
}

property code_comment_color: Color {
  target: text | code | math | figure | page_number | toc
}

property code_string_color: Color {
  target: text | code | math | figure | page_number | toc
}

property math_scale: ScalarLike {
  target: math
}

property asset_scale: ScalarLike {
  target: asset_image | asset_pdf
}

property chrome_fill: Color {
  target: panel | rule
}

property chrome_stroke: Color {
  target: panel | rule
}

property chrome_line_width: ScalarLike {
  target: panel | rule
}

property chrome_radius: ScalarLike {
  target: panel | rule
}

property rule_stroke: Color {
  target: rule
}

property rule_line_width: ScalarLike {
  target: rule
}

property rule_dash: string {
  target: rule
}
