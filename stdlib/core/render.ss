import std:core/objects

fn with_prop(obj: object, key_name: string, value_name: string) -> object
  set_prop(obj, key_name, value_name)
  return obj
end

fn with_asset_scale(obj: object, scale: number) -> object
  set_prop(obj, "asset_scale", str(scale))
  return obj
end

fn text_paint(obj: object, font_name: string, font_size_name: string, line_height_name: string, color_name: string) -> object
  set_prop(obj, "text_font", font_name)
  set_prop(obj, "text_size", font_size_name)
  set_prop(obj, "text_line_height", line_height_name)
  set_prop(obj, "text_color", color_name)
  return obj
end

fn text_layout(obj: object, font_size_name: string, line_height_name: string, spacing_after_name: string, left_name: string, right_name: string) -> object
  set_prop(obj, "layout_font_size", font_size_name)
  set_prop(obj, "layout_line_height", line_height_name)
  set_prop(obj, "layout_spacing_after", spacing_after_name)
  set_prop(obj, "layout_x", left_name)
  set_prop(obj, "layout_right_inset", right_name)
  return obj
end

fn text_preset(obj: object, font_name: string, font_size_name: string, line_height_name: string, color_name: string, spacing_after_name: string, left_name: string, right_name: string) -> object
  text_paint(obj, font_name, font_size_name, line_height_name, color_name)
  text_layout(obj, font_size_name, line_height_name, spacing_after_name, left_name, right_name)
  return obj
end

fn markdown_code_paint(obj: object, font_size_name: string, line_height_name: string, pad_x_name: string, pad_y_name: string, fill_name: string, stroke_name: string, line_width_name: string, radius_name: string) -> object
  set_prop(obj, "text_markdown_code_font_size", font_size_name)
  set_prop(obj, "text_markdown_code_line_height", line_height_name)
  set_prop(obj, "text_markdown_code_pad_x", pad_x_name)
  set_prop(obj, "text_markdown_code_pad_y", pad_y_name)
  set_prop(obj, "text_markdown_code_fill", fill_name)
  set_prop(obj, "text_markdown_code_stroke", stroke_name)
  set_prop(obj, "text_markdown_code_line_width", line_width_name)
  set_prop(obj, "text_markdown_code_radius", radius_name)
  return obj
end

fn chrome_paint(obj: object, fill_name: string, stroke_name: string, line_width_name: string, radius_name: string) -> object
  set_prop(obj, "chrome_fill", fill_name)
  set_prop(obj, "chrome_stroke", stroke_name)
  set_prop(obj, "chrome_line_width", line_width_name)
  set_prop(obj, "chrome_radius", radius_name)
  return obj
end

fn underline_paint(obj: object, color_name: string, line_width_name: string, offset_name: string) -> object
  set_prop(obj, "underline_color", color_name)
  set_prop(obj, "underline_width", line_width_name)
  set_prop(obj, "underline_offset", offset_name)
  return obj
end

fn rule_paint(obj: object, stroke_name: string, line_width_name: string, dash_name: string) -> object
  set_prop(obj, "rule_stroke", stroke_name)
  set_prop(obj, "rule_line_width", line_width_name)
  set_prop(obj, "rule_dash", dash_name)
  return obj
end

fn fit_policy(obj: object, policy_name: string) -> object
  set_prop(obj, "fit", policy_name)
  return obj
end

fn overflow_warning(obj: object) -> object
  return fit_policy(obj, "warn")
end

fn overflow_error(obj: object) -> object
  return fit_policy(obj, "error")
end

fn ignore_overflow(obj: object) -> object
  return fit_policy(obj, "ignore")
end

fn styled_text(text_value: string, role_name: string, style_value: style) -> object
  let obj = text_object(text_value, role_name)
  set_style(obj, style_value)
  return obj
end

fn title_variant(text_value: string, variant_name: string) -> object
  return styled_text(text_value, "title", style(variant_name))
end

fn subtitle_variant(text_value: string, variant_name: string) -> object
  return styled_text(text_value, "subtitle", style(variant_name))
end

fn byline(text_value: string) -> object
  let byline = text_object(text_value, "byline")
  return byline
end

fn byline_variant(text_value: string, variant_name: string) -> object
  return styled_text(text_value, "byline", style(variant_name))
end

fn label(label_style_name: string, text_value: string) -> object
  return styled_text(text_value, "label", style(label_style_name))
end

fn rule(rule_style_name: string) -> object
  let obj = rule_object()
  set_style(obj, style(rule_style_name))
  return obj
end
