fn text_object(text_value, role_name) {
  let obj = object(text_value, role_name, "text")
  return obj
}

fn title_object(text_value) {
  return text_object(text_value, "title")
}

fn subtitle_object(text_value) {
  return text_object(text_value, "subtitle")
}

fn body_object(text_value) {
  return text_object(text_value, "body")
}

fn note_object(text_value) {
  return text_object(text_value, "note")
}

fn byline_object(text_value) {
  return text_object(text_value, "byline")
}

fn label_object(text_value) {
  return text_object(text_value, "label")
}

fn rule_object() {
  return text_object("", "rule")
}

fn payload_object(text_value, role_name, payload_name) {
  let obj = object(text_value, role_name, payload_name)
  return obj
}

fn math_text_object(text_value) {
  return payload_object(text_value, "math", "math_text")
}

fn math_tex_object(text_value) {
  return payload_object(text_value, "math", "math_tex")
}

fn figure_text_object(text_value) {
  return payload_object(text_value, "figure", "figure_text")
}

fn image_object(path_value) {
  return payload_object(path_value, "figure", "image_ref")
}

fn pdf_object(path_value) {
  return payload_object(path_value, "figure", "pdf_ref")
}

fn inset_object(text_value, role_name, payload_name, left, right) {
  let obj = payload_object(text_value, role_name, payload_name)
  inset_x(obj, left, right)
  return obj
}

fn inset_text(text_value, role_name, left, right) {
  let obj = text_object(text_value, role_name)
  inset_x(obj, left, right)
  return obj
}

fn with_prop(obj, key_name, value_name) {
  set_prop(obj, key_name, value_name)
  return obj
}

fn text_paint(obj, font_name, font_size_name, line_height_name, color_name) {
  set_prop(obj, "text_font", font_name)
  set_prop(obj, "text_size", font_size_name)
  set_prop(obj, "text_line_height", line_height_name)
  set_prop(obj, "text_color", color_name)
  return obj
}

fn text_layout(obj, font_size_name, line_height_name, spacing_after_name, left_name, right_name) {
  set_prop(obj, "layout_font_size", font_size_name)
  set_prop(obj, "layout_line_height", line_height_name)
  set_prop(obj, "layout_spacing_after", spacing_after_name)
  set_prop(obj, "layout_x", left_name)
  set_prop(obj, "layout_right_inset", right_name)
  return obj
}

fn text_preset(obj, font_name, font_size_name, line_height_name, color_name, spacing_after_name, left_name, right_name) {
  text_paint(obj, font_name, font_size_name, line_height_name, color_name)
  text_layout(obj, font_size_name, line_height_name, spacing_after_name, left_name, right_name)
  return obj
}

fn markdown_code_paint(obj, font_size_name, line_height_name, pad_x_name, pad_y_name, fill_name, stroke_name, line_width_name, radius_name) {
  set_prop(obj, "text_markdown_code_font_size", font_size_name)
  set_prop(obj, "text_markdown_code_line_height", line_height_name)
  set_prop(obj, "text_markdown_code_pad_x", pad_x_name)
  set_prop(obj, "text_markdown_code_pad_y", pad_y_name)
  set_prop(obj, "text_markdown_code_fill", fill_name)
  set_prop(obj, "text_markdown_code_stroke", stroke_name)
  set_prop(obj, "text_markdown_code_line_width", line_width_name)
  set_prop(obj, "text_markdown_code_radius", radius_name)
  return obj
}

fn chrome_paint(obj, fill_name, stroke_name, line_width_name, radius_name) {
  set_prop(obj, "chrome_fill", fill_name)
  set_prop(obj, "chrome_stroke", stroke_name)
  set_prop(obj, "chrome_line_width", line_width_name)
  set_prop(obj, "chrome_radius", radius_name)
  return obj
}

fn underline_paint(obj, color_name, line_width_name, offset_name) {
  set_prop(obj, "underline_color", color_name)
  set_prop(obj, "underline_width", line_width_name)
  set_prop(obj, "underline_offset", offset_name)
  return obj
}

fn rule_paint(obj, stroke_name, line_width_name, dash_name) {
  set_prop(obj, "rule_stroke", stroke_name)
  set_prop(obj, "rule_line_width", line_width_name)
  set_prop(obj, "rule_dash", dash_name)
  return obj
}

fn fit_policy(obj, policy_name) {
  set_prop(obj, "fit", policy_name)
  return obj
}

fn overflow_warning(obj) {
  return fit_policy(obj, "warn")
}

fn overflow_error(obj) {
  return fit_policy(obj, "error")
}

fn ignore_overflow(obj) {
  return fit_policy(obj, "ignore")
}

fn styled_text(text_value, role_name, style_value) {
  let obj = text_object(text_value, role_name)
  set_style(obj, style_value)
  return obj
}

fn title_variant(text_value, variant_name) {
  return styled_text(text_value, "title", style(variant_name))
}

fn subtitle_variant(text_value, variant_name) {
  return styled_text(text_value, "subtitle", style(variant_name))
}

fn byline(text_value) {
  let byline = text_object(text_value, "byline")
  return byline
}

fn byline_variant(text_value, variant_name) {
  return styled_text(text_value, "byline", style(variant_name))
}

fn label(label_style_name, text_value) {
  return styled_text(text_value, "label", style(label_style_name))
}

fn rule(rule_style_name) {
  let obj = rule_object()
  set_style(obj, style(rule_style_name))
  return obj
}

fn left_inset(node, amount) {
  return equal(anchor(node, "left"), page_anchor("left"), amount)
}

fn right_inset(node, amount) {
  return equal(anchor(node, "right"), page_anchor("right"), neg(amount))
}

fn top_inset(node, amount) {
  return equal(anchor(node, "top"), page_anchor("top"), neg(amount))
}

fn bottom_inset(node, amount) {
  return equal(anchor(node, "bottom"), page_anchor("bottom"), amount)
}

fn same_left(target, source, delta) {
  return equal(anchor(target, "left"), anchor(source, "left"), delta)
}

fn same_right(target, source, delta) {
  return equal(anchor(target, "right"), anchor(source, "right"), delta)
}

fn same_top(target, source, delta) {
  return equal(anchor(target, "top"), anchor(source, "top"), delta)
}

fn same_bottom(target, source, delta) {
  return equal(anchor(target, "bottom"), anchor(source, "bottom"), delta)
}

fn below(target, source, gap) {
  return equal(anchor(target, "top"), anchor(source, "bottom"), neg(gap))
}

fn fixed_width(node, width) {
  return equal(anchor(node, "right"), anchor(node, "left"), width)
}

fn fixed_height(node, height) {
  return equal(anchor(node, "top"), anchor(node, "bottom"), height)
}

fn inset_x(node, left, right) {
  return constraints(
    left_inset(node, left),
    right_inset(node, right)
  )
}

fn inset_node(node, left, right) {
  inset_x(node, left, right)
  return node
}

fn flow_inset(node, left, right) {
  set_prop(node, "layout_x", left)
  set_prop(node, "layout_right_inset", right)
  return node
}

fn place_top_left(node, left, top) {
  left_inset(node, left)
  top_inset(node, top)
  return node
}

fn place_top_right(node, right, top) {
  right_inset(node, right)
  top_inset(node, top)
  return node
}

fn place_top_span(node, left, right, top) {
  inset_x(node, left, right)
  top_inset(node, top)
  return node
}

fn place_below_left(target, source, left_delta, gap) {
  same_left(target, source, left_delta)
  below(target, source, gap)
  return target
}

fn place_below_right(target, source, right_delta, gap) {
  same_right(target, source, right_delta)
  below(target, source, gap)
  return target
}

fn place_same_top_right(node, source, right, top_delta) {
  right_inset(node, right)
  same_top(node, source, top_delta)
  return node
}

fn two_columns_constraints(left, right, gap, right_inset_value) {
  return constraints(
    equal(anchor(right, "left"), anchor(left, "right"), gap),
    same_top(right, left, 0),
    left_inset(left, 96),
    ;; right_inset(right, right_inset_value)
  )
}

fn two_columns_gap(left, right, gap) {
  two_columns_constraints(left, right, gap, 96)
  return group(left, right)
}

fn two_columns(left, right) {
  return two_columns_gap(left, right, 30)
}

fn surround(panel, inner, pad_x, pad_y) {
  return constraints(
    equal(anchor(panel, "left"), anchor(inner, "left"), neg(pad_x)),
    equal(anchor(panel, "right"), anchor(inner, "right"), pad_x),
    equal(anchor(panel, "top"), anchor(inner, "top"), pad_y),
    equal(anchor(panel, "bottom"), anchor(inner, "bottom"), neg(pad_y))
  )
}

fn panel(style_value) {
  let panel = text_object("", "panel")
  set_style(panel, style_value)
  return panel
}

fn page_background(fill_name) {
  let bg = panel(style("custom"))
  set_prop(bg, "chrome_fill", fill_name)
  set_prop(bg, "chrome_line_width", "0")
  set_prop(bg, "chrome_radius", "0")
  left_inset(bg, 0)
  right_inset(bg, 0)
  top_inset(bg, 0)
  bottom_inset(bg, 0)
  return bg
}

fn frame_with_style(inner, panel_style_name, pad_x, pad_y) {
  surround_object(panel_style_name, inner, pad_x, pad_y)
  return inner
}

fn framed_object(text_value, role_name, payload_name, left, right, pad_x, pad_y, fill_name, stroke_name, line_width_name, radius_name) {
  let inner = payload_object(text_value, role_name, payload_name)
  flow_inset(inner, left, right)
  let chrome = panel(style("custom"))
  chrome_paint(chrome, fill_name, stroke_name, line_width_name, radius_name)
  surround(chrome, inner, pad_x, pad_y)
  return inner
}

fn surround_object(panel_style_name, inner, pad_x, pad_y) {
  let chrome = panel(style(panel_style_name))
  surround(chrome, inner, pad_x, pad_y)
  return inner
}

fn panel_block(text_value, role_name, payload_name, panel_style_name, left, right, pad_x, pad_y) {
  let inner = payload_object(text_value, role_name, payload_name)
  flow_inset(inner, left, right)
  surround_object(panel_style_name, inner, pad_x, pad_y)
  return inner
}

fn code_object(text_value) {
  let code = payload_object(text_value, "code", "code")
  return code
}

fn page_number_object() {
  let page_no = derive(pagectx(), "page_number")
  overflow_error(page_no)
  return page_no
}

fn toc_list_object() {
  let toc = derive(docctx(), "toc")
  return toc
}

fn code_with_language(text_value, language_name) {
  let code = code_object(text_value)
  set_prop(code, "language", language_name)
  return code
}

fn python_code_object(text_value) {
  return code_with_language(text_value, "python")
}

fn inset_code_with_language(text_value, language_name, left, right) {
  let code = code_with_language(text_value, language_name)
  flow_inset(code, left, right)
  return code
}

fn panel_code_with_language(text_value, language_name, panel_style_name, left, right, pad_x, pad_y) {
  let code = inset_code_with_language(text_value, language_name, left, right)
  surround_object(panel_style_name, code, pad_x, pad_y)
  return code
}

fn framed_code_with_language(text_value, language_name, left, right, pad_x, pad_y, fill_name, stroke_name, line_width_name, radius_name) {
  let code = inset_code_with_language(text_value, language_name, left, right)
  let chrome = panel(style("custom"))
  chrome_paint(chrome, fill_name, stroke_name, line_width_name, radius_name)
  surround(chrome, code, pad_x, pad_y)
  return code
}

fn text(text_value) {
  return body_object(text_value)
}

fn lead(text_value) {
  return text(text_value)
}

fn math_block(text_value) {
  return flow_inset(math_text_object(text_value), "102", "102")
}

fn tex(text_value) {
  return flow_inset(math_tex_object(text_value), "102", "102")
}

fn figure(text_value) {
  return flow_inset(figure_text_object(text_value), "102", "102")
}

fn image(path_value) {
  return flow_inset(image_object(path_value), "102", "102")
}

fn pdf(path_value) {
  return flow_inset(pdf_object(path_value), "102", "102")
}

fn plain_code(text_value) {
  let code = code_object(text_value)
  flow_inset(code, "102", "102")
  return code
}

fn code(text_value) {
  let code = python_code_object(text_value)
  flow_inset(code, "102", "102")
  return code
}

fn python_code(text_value) {
  code(text_value)
}

fn note(text_value) {
  return flow_inset(note_object(text_value), "120", "120")
}

fn callout(text_value) {
  return note(text_value)
}

fn quote(text_value) {
  return note(text_value)
}

fn page_no() {
  let page_no = page_number_object()
  return page_no
}
