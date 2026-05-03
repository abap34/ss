fn text_object(text_value: string, role_name: string) -> object
  let obj = object(text_value, role_name, "text")
  return obj
end

fn title_object(text_value: string) -> object
  return text_object(text_value, "title")
end

fn subtitle_object(text_value: string) -> object
  return text_object(text_value, "subtitle")
end

fn body_object(text_value: string) -> object
  return text_object(text_value, "body")
end

fn note_object(text_value: string) -> object
  return text_object(text_value, "note")
end

fn byline_object(text_value: string) -> object
  return text_object(text_value, "byline")
end

fn label_object(text_value: string) -> object
  return text_object(text_value, "label")
end

fn rule_object() -> object
  return text_object("", "rule")
end

fn spacer(height: number, width: number = 1) -> object
  let obj = text_object("", "panel")
  fixed_height(obj, height)
  fixed_width(obj, width)
  return obj
end

fn vspace(height: number) -> object
  return spacer(height)
end

fn payload_object(text_value: string, role_name: string, payload_name: string) -> object
  let obj = object(text_value, role_name, payload_name)
  return obj
end

fn math_text_object(text_value: string) -> object
  return payload_object(text_value, "math", "math_text")
end

fn math_tex_object(text_value: string) -> object
  return payload_object(text_value, "math", "math_tex")
end

fn figure_text_object(text_value: string) -> object
  return payload_object(text_value, "figure", "figure_text")
end

fn image_object(path_value: string) -> object
  return payload_object(path_value, "figure", "image_ref")
end

fn pdf_object(path_value: string) -> object
  return payload_object(path_value, "figure", "pdf_ref")
end

fn inset_object(text_value: string, role_name: string, payload_name: string, left: number, right: number) -> object
  let obj = payload_object(text_value, role_name, payload_name)
  inset_x(obj, left, right)
  return obj
end

fn inset_text(text_value: string, role_name: string, left: number, right: number) -> object
  let obj = text_object(text_value, role_name)
  inset_x(obj, left, right)
  return obj
end

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

fn left_inset(node: object, amount: number) -> constraints
  return equal(anchor(node, "left"), page_anchor("left"), amount)
end

fn right_inset(node: object, amount: number) -> constraints
  return equal(anchor(node, "right"), page_anchor("right"), neg(amount))
end

fn top_inset(node: object, amount: number) -> constraints
  return equal(anchor(node, "top"), page_anchor("top"), neg(amount))
end

fn bottom_inset(node: object, amount: number) -> constraints
  return equal(anchor(node, "bottom"), page_anchor("bottom"), amount)
end

fn same_left(target: object, source: object, delta: number) -> constraints
  return equal(anchor(target, "left"), anchor(source, "left"), delta)
end

fn same_right(target: object, source: object, delta: number) -> constraints
  return equal(anchor(target, "right"), anchor(source, "right"), delta)
end

fn same_top(target: object, source: object, delta: number) -> constraints
  return equal(anchor(target, "top"), anchor(source, "top"), delta)
end

fn same_bottom(target: object, source: object, delta: number) -> constraints
  return equal(anchor(target, "bottom"), anchor(source, "bottom"), delta)
end

fn below(target: object, source: object, gap: number) -> constraints
  return equal(anchor(target, "top"), anchor(source, "bottom"), neg(gap))
end

fn fixed_width(node: object, width: number) -> constraints
  return equal(anchor(node, "right"), anchor(node, "left"), width)
end

fn fixed_height(node: object, height: number) -> constraints
  return equal(anchor(node, "top"), anchor(node, "bottom"), height)
end

fn inset_x(node: object, left: number, right: number) -> constraints
  return constraints(
    left_inset(node, left),
    right_inset(node, right)
  )
end

fn inset_node(node: object, left: number, right: number) -> object
  inset_x(node, left, right)
  return node
end

fn flow_inset(node: object, left: string, right: string) -> object
  set_prop(node, "layout_x", left)
  set_prop(node, "layout_right_inset", right)
  return node
end

fn place_top_left(node: object, left: number, top: number) -> object
  left_inset(node, left)
  top_inset(node, top)
  return node
end

fn place_top_right(node: object, right: number, top: number) -> object
  right_inset(node, right)
  top_inset(node, top)
  return node
end

fn place_top_span(node: object, left: number, right: number, top: number) -> object
  inset_x(node, left, right)
  top_inset(node, top)
  return node
end

fn place_below_left(target: object, source: object, left_delta: number, gap: number) -> object
  same_left(target, source, left_delta)
  below(target, source, gap)
  return target
end

fn place_below_right(target: object, source: object, right_delta: number, gap: number) -> object
  same_right(target, source, right_delta)
  below(target, source, gap)
  return target
end

fn place_same_top_right(node: object, source: object, right: number, top_delta: number) -> object
  right_inset(node, right)
  same_top(node, source, top_delta)
  return node
end

fn two_columns_constraints(left: object, right: object, gap: number, right_inset_value: number) -> constraints
  return constraints(
    equal(anchor(right, "left"), anchor(left, "right"), gap),
    same_top(right, left, 0),
    left_inset(left, 96),
    ;; right_inset(right, right_inset_value)
  )
end

fn two_columns_gap(left: object, right: object, gap: number) -> object
  two_columns_constraints(left, right, gap, 96)
  return group(left, right)
end

fn two_columns(left: object, right: object) -> object
  return two_columns_gap(left, right, 30)
end

fn surround(panel: object, inner: object, pad_x: number, pad_y: number) -> constraints
  return constraints(
    equal(anchor(panel, "left"), anchor(inner, "left"), neg(pad_x)),
    equal(anchor(panel, "right"), anchor(inner, "right"), pad_x),
    equal(anchor(panel, "top"), anchor(inner, "top"), pad_y),
    equal(anchor(panel, "bottom"), anchor(inner, "bottom"), neg(pad_y))
  )
end

fn panel(style_value: style) -> object
  let panel = text_object("", "panel")
  set_style(panel, style_value)
  return panel
end

fn page_background(fill_name: string) -> object
  let bg = panel(style("custom"))
  set_prop(bg, "chrome_fill", fill_name)
  set_prop(bg, "chrome_line_width", "0")
  set_prop(bg, "chrome_radius", "0")
  left_inset(bg, 0)
  right_inset(bg, 0)
  top_inset(bg, 0)
  bottom_inset(bg, 0)
  return bg
end

fn frame_with_style(inner: object, panel_style_name: string, pad_x: number, pad_y: number) -> object
  surround_object(panel_style_name, inner, pad_x, pad_y)
  return inner
end

fn framed_object(text_value: string, role_name: string, payload_name: string, left: string, right: string, pad_x: number, pad_y: number, fill_name: string, stroke_name: string, line_width_name: string, radius_name: string) -> object
  let inner = payload_object(text_value, role_name, payload_name)
  flow_inset(inner, left, right)
  let chrome = panel(style("custom"))
  chrome_paint(chrome, fill_name, stroke_name, line_width_name, radius_name)
  surround(chrome, inner, pad_x, pad_y)
  return inner
end

fn surround_object(panel_style_name: string, inner: object, pad_x: number, pad_y: number) -> object
  let chrome = panel(style(panel_style_name))
  surround(chrome, inner, pad_x, pad_y)
  return inner
end

fn panel_block(text_value: string, role_name: string, payload_name: string, panel_style_name: string, left: string, right: string, pad_x: number, pad_y: number) -> object
  let inner = payload_object(text_value, role_name, payload_name)
  flow_inset(inner, left, right)
  surround_object(panel_style_name, inner, pad_x, pad_y)
  return inner
end

fn code_object(text_value: string) -> object
  let code = payload_object(text_value, "code", "code")
  return code
end

fn page_number_object() -> object
  let page_no = derive(pagectx(), "page_number")
  overflow_error(page_no)
  return page_no
end

fn toc_list_object() -> object
  let toc = derive(docctx(), "toc")
  return toc
end

fn code_with_language(text_value: string, language_name: string) -> object
  let code = code_object(text_value)
  set_prop(code, "language", language_name)
  return code
end

fn python_code_object(text_value: string) -> object
  return code_with_language(text_value, "python")
end

fn inset_code_with_language(text_value: string, language_name: string, left: string, right: string) -> object
  let code = code_with_language(text_value, language_name)
  flow_inset(code, left, right)
  return code
end

fn panel_code_with_language(text_value: string, language_name: string, panel_style_name: string, left: string, right: string, pad_x: number, pad_y: number) -> object
  let code = inset_code_with_language(text_value, language_name, left, right)
  surround_object(panel_style_name, code, pad_x, pad_y)
  return code
end

fn framed_code_with_language(text_value: string, language_name: string, left: string, right: string, pad_x: number, pad_y: number, fill_name: string, stroke_name: string, line_width_name: string, radius_name: string) -> object
  let code = inset_code_with_language(text_value, language_name, left, right)
  let chrome = panel(style("custom"))
  chrome_paint(chrome, fill_name, stroke_name, line_width_name, radius_name)
  surround(chrome, code, pad_x, pad_y)
  return code
end

fn text(text_value: string) -> object
  return body_object(text_value)
end

fn lead(text_value: string) -> object
  return text(text_value)
end

fn math_block(text_value: string) -> object
  return flow_inset(math_text_object(text_value), "102", "102")
end

fn tex(text_value: string) -> object
  return flow_inset(math_tex_object(text_value), "102", "102")
end

fn figure(text_value: string) -> object
  return flow_inset(figure_text_object(text_value), "102", "102")
end

fn unchecked_image(path_value: string, scale: number = 1) -> object
  return with_asset_scale(flow_inset(image_object(path_value), "102", "102"), scale)
end

fn image(path_value: string, scale: number = 1) -> object
  let obj = unchecked_image(path_value, scale)
  require_asset_exists(obj)
  return obj
end

fn checked_image(path_value: string, scale: number = 1) -> object
  return image(path_value, scale)
end

fn pdf(path_value: string, scale: number = 1) -> object
  let obj = with_asset_scale(flow_inset(pdf_object(path_value), "102", "102"), scale)
  require_asset_exists(obj)
  return obj
end

fn checked_pdf(path_value: string, scale: number = 1) -> object
  return pdf(path_value, scale)
end

fn plain_code(text_value: string) -> object
  let code = code_object(text_value)
  flow_inset(code, "102", "102")
  return code
end

fn code(text_value: string) -> object
  let code = python_code_object(text_value)
  flow_inset(code, "102", "102")
  return code
end

fn python_code(text_value: string) -> object
  return code(text_value)
end

fn note(text_value: string) -> object
  return flow_inset(note_object(text_value), "120", "120")
end

fn callout(text_value: string) -> object
  return note(text_value)
end

fn quote(text_value: string) -> object
  return note(text_value)
end

fn page_no() -> object
  let page_no = page_number_object()
  return page_no
end
