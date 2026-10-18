import std:layout/types as { LayoutPolicy, Align }

type PageSettings {
  layout_h: LayoutPolicy = LayoutPolicy.left
  layout_h_center_offset: Number = 0
  layout_v: LayoutPolicy = LayoutPolicy.center
  layout_v_center_offset: Number = 0
  background_fill: Color? = none
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
