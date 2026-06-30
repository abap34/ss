import std:core/classes as *
import std:core/layout as *
import std:core/objects as *
import std:core/render as *
import std:core/selectors as *
import std:core/utils as *
import std:core/generated as *

fn/! title(text_value: String) -> Object
  return title_obj(text_value)
end

fn/! subtitle(text_value: String) -> Object
  return sub_obj(text_value)
end

fn/! math(text_value: String, scale: Number = 1) -> Object
  let obj = math_obj(text_value)
  obj.math_scale = scale
  return obj
end

fn/! mathtex(text_value: String) -> Object
  return math_obj(text_value)
end

fn/! panel() -> Object
  return panel_obj()
end

fn/! byline(text_value: String) -> Object
  return by_obj(text_value)
end

fn/! label(text_value: String) -> Object
  return lab_obj(text_value)
end

fn/! rule() -> Object
  return rule_obj()
end

record LineStyle {
  stroke: Color? = c"#4b5563"
  line_width: Number = 1.6
  dash: String = ""
  marker_start: ShapeMarker = ShapeMarker.plain
  marker_end: ShapeMarker = ShapeMarker.plain
  marker_size: Number = 10
}

record CalloutStyle {
  left_bracket: Bool = false
  stroke: Color? = c"#4b5563"
  line_width: Number = 1.6
  dash: String = ""
  marker_size: Number = 10
  bracket_width: Number = 24
  bracket_pad_x: Number = 14
  bracket_pad_y: Number = 8
  text_size: Number = 17
  text_line_height: Number = 25
  text_color: Color = c"#374151"
  text_weight: Number = 400
  fill: Color? = none
  border: Color? = c"#4b5563"
  border_width: Number = 1
  radius: Number = 6
  pad_x: Number = 18
  pad_y: Number = 12
  rises: Bool = true
}

record MarkedCalloutStyle {
  x: Number = 96
  top_y: Number = 220
  text_size: Number = 25
  text_line_height: Number = 34
  text_color: Color = c"#111827"
  text_weight: Number = 400
  target_color: Color = c"#111827"
  target_weight: Number = 700
  target_fill: Color? = none
  target_border: Color? = none
  target_border_width: Number = 0
  target_radius: Number = 0
  target_pad_x: Number = 0
  target_pad_y: Number = 0
  callout_x: Number = 780
  callout_top_y: Number = 486
  callout_width: Number = 300
  rises: Bool = true
  callout: CalloutStyle = CalloutStyle {}
}

fn/! line() -> Object
  return shape_obj()
end

fn line_s(obj: Object, style: LineStyle) -> Object
  obj.shape_stroke = style.stroke
  obj.shape_line_width = style.line_width
  obj.shape_dash = style.dash
  obj.shape_marker_start = style.marker_start
  obj.shape_marker_end = style.marker_end
  obj.shape_marker_size = style.marker_size
  return obj
end

fn/! line_up(from: Object, to: Object, style: LineStyle = LineStyle {}) -> Object
  let obj = line_s(line(), style)
  obj.shape_start_y = 0
  obj.shape_end_y = 1
  ~ obj.left == from.right
  ~ obj.bottom == from.center_y
  ~ obj.right == to.left
  ~ obj.top == to.center_y
  return obj
end

fn/! line_down(from: Object, to: Object, style: LineStyle = LineStyle {}) -> Object
  let obj = line_s(line(), style)
  obj.shape_start_y = 1
  obj.shape_end_y = 0
  ~ obj.left == from.right
  ~ obj.top == from.center_y
  ~ obj.right == to.left
  ~ obj.bottom == to.center_y
  return obj
end

fn/! arrow_up(from: Object, to: Object, style: LineStyle = LineStyle {}) -> Object
  return line_up(from, to, style with {
    marker_end = ShapeMarker.arrow
  })
end

fn/! arrow_down(from: Object, to: Object, style: LineStyle = LineStyle {}) -> Object
  return line_down(from, to, style with {
    marker_end = ShapeMarker.arrow
  })
end

fn/! callout_text(text_value: String, style: CalloutStyle) -> Object
  let obj = body_obj(text_value)
  obj.text = TextStyle {
    font = FontFace { family = "Helvetica" weight = style.text_weight }
    size = style.text_size
    line_height = style.text_line_height
    color = style.text_color
  }
  obj.layout = LayoutStyle {
    spacing_after = 0
    x = 0
    right_inset = 0
    wrap = WrapMode.on
    fit = FitPolicy.warn
  }
  return obj
end

fn/! callout_bar(color_name: Color?, thickness: Number) -> Object
  let obj = panel()
  box(obj, color_name, none, 0, div(thickness, 2))
  obj.layout_font_size = 1
  obj.layout_line_height = 1
  return obj
end

fn/! callout_hbar(color_name: Color?, thickness: Number) -> Object
  let obj = callout_bar(color_name, thickness)
  ~ obj.height == thickness
  return obj
end

fn/! callout_vbar(color_name: Color?, thickness: Number) -> Object
  let obj = callout_bar(color_name, thickness)
  ~ obj.width == thickness
  return obj
end

fn/! callout_left_bracket(inner: Object, style: CalloutStyle) -> Object
  let side = callout_vbar(style.stroke, style.line_width)
  let top = callout_hbar(style.stroke, style.line_width)
  let bottom = callout_hbar(style.stroke, style.line_width)
  ~ side.right == inner.left - style.bracket_pad_x
  ~ side.top == inner.top + style.bracket_pad_y
  ~ side.bottom == inner.bottom - style.bracket_pad_y
  ~ top.left == side.left
  ~ top.right == side.left + style.bracket_width
  ~ top.top == side.top
  ~ bottom.left == side.left
  ~ bottom.right == side.left + style.bracket_width
  ~ bottom.bottom == side.bottom
  return group(side, top, bottom)
end

fn/! bracket_callout(target: Object, text_value: String, x: Number, top_y: Number, width: Number, style: CalloutStyle = CalloutStyle {}) -> Object
  let note = callout_text(text_value, style)
  ~ note.left == page.left + x
  ~ note.right == note.left + width
  ~ note.top == page.top - top_y

  let chrome = panel()
  box(chrome, style.fill, style.border, style.border_width, style.radius)
  surround(chrome, note, style.pad_x, style.pad_y)

  let connector_style = LineStyle {
    stroke = style.stroke
    line_width = style.line_width
    dash = style.dash
    marker_end = ShapeMarker.arrow
    marker_size = style.marker_size
  }
  let connector = line()
  line_s(connector, connector_style)
  if style.left_bracket
    let bracket = callout_left_bracket(chrome, style)
    if style.rises
      connector.shape_start_y = 0
      connector.shape_end_y = 1
      ~ connector.left == target.right
      ~ connector.bottom == target.center_y
      ~ connector.right == bracket.left
      ~ connector.top == bracket.center_y
    else
      connector.shape_start_y = 1
      connector.shape_end_y = 0
      ~ connector.left == target.right
      ~ connector.top == target.center_y
      ~ connector.right == bracket.left
      ~ connector.bottom == bracket.center_y
    end
    return group(note, chrome, bracket, connector)
  else
    if style.rises
      connector.shape_start_y = 0
      connector.shape_end_y = 1
      ~ connector.left == target.right
      ~ connector.bottom == target.center_y
      ~ connector.right == chrome.left
      ~ connector.top == chrome.center_y
    else
      connector.shape_start_y = 1
      connector.shape_end_y = 0
      ~ connector.left == target.right
      ~ connector.top == target.center_y
      ~ connector.right == chrome.left
      ~ connector.bottom == chrome.center_y
    end
    return group(note, chrome, connector)
  end
end

fn/! marked_callout_text(text_value: String, color_name: Color, weight: Number, size: Number, line_height: Number) -> Object
  let obj = body_obj(text_value)
  obj.text = TextStyle {
    font = FontFace { family = "Helvetica" weight = weight }
    size = size
    line_height = line_height
    color = color_name
  }
  obj.layout = LayoutStyle {
    spacing_after = 0
    x = 0
    right_inset = 0
    wrap = WrapMode.off
    fit = FitPolicy.warn
  }
  return obj
end

fn marked_callout!(source_text: String, target_text: String, note_text: String, style: MarkedCalloutStyle = MarkedCalloutStyle {}) -> Object
  if not(str_contains(source_text, target_text))
    report_warning("MarkedCalloutTargetMissing: target text was not found in source text")
  end

  let before = marked_callout_text!(str_before(source_text, target_text), style.text_color, style.text_weight, style.text_size, style.text_line_height)
  let target = marked_callout_text!(target_text, style.target_color, style.target_weight, style.text_size, style.text_line_height)
  let after = marked_callout_text!(str_after(source_text, target_text), style.text_color, style.text_weight, style.text_size, style.text_line_height)

  let target_back = panel!()
  box(target_back, style.target_fill, style.target_border, style.target_border_width, style.target_radius)
  surround(target_back, target, style.target_pad_x, style.target_pad_y)

  ~ before.left == page.left + style.x
  ~ before.top == page.top - style.top_y
  ~ target.left == before.right + style.target_pad_x
  ~ target.top == before.top
  ~ after.left == target.right + style.target_pad_x
  ~ after.top == before.top

  let callout_style = style.callout with {
    rises = style.rises
  }
  let callout = bracket_callout!(target, note_text, style.callout_x, style.callout_top_y, style.callout_width, callout_style)
  return place!(group(before, target, after, target_back, callout))
end

fn annotate!(source_text: String, target_text: String, note_text: String, style: MarkedCalloutStyle = MarkedCalloutStyle {}) -> Object
  return marked_callout!(source_text, target_text, note_text, style)
end

fn annotate_down!(source_text: String, target_text: String, note_text: String, style: MarkedCalloutStyle = MarkedCalloutStyle {}) -> Object
  return marked_callout!(source_text, target_text, note_text, style with {
    rises = false
  })
end

fn page_bg(fill_name: Color?) -> Void
  pagectx().background_fill = fill_name
end

fn doc_bg(fill_name: Color?) -> Void
  docctx().background_fill = fill_name
end

fn/! frame_s(inner: Object, pad_x: Number, pad_y: Number) -> Object
  surround_s(inner, pad_x, pad_y)
  return inner
end

fn/! frame(text_value: String, role_name: String, payload_name: String, left: Number, right: Number, pad_x: Number, pad_y: Number, fill_name: Color?, stroke_name: Color?, line_width_name: Number, radius_name: Number) -> Object
  let inner = raw_obj(text_value, role_name, payload_name)
  inner.layout_x = left
  inner.layout_right_inset = right
  inner.wrap = WrapMode.on
  let chrome = panel()
  box(chrome, fill_name, stroke_name, line_width_name, radius_name)
  chrome.layout_spacing_after = 34
  surround(chrome, inner, pad_x, pad_y)
  return inner
end

fn surround_s(inner: Object, pad_x: Number, pad_y: Number) -> Object
  let chrome = panel()
  surround(chrome, inner, pad_x, pad_y)
  return inner
end

fn border_p(inner: Object, pad_x: Number, pad_y: Number, fill_name: Color?, stroke_name: Color?, line_width: Number, radius: Number) -> Object
  box(inner, fill_name, stroke_name, line_width, radius)
  inner.chrome_pad_x = pad_x
  inner.chrome_pad_y = pad_y
  return inner
end

fn border(inner: Object, pad_x: Number = 12, pad_y: Number = 8, stroke_name: Color? = c"0.36,0.40,0.48", line_width: Number = 1, radius: Number = 8) -> Object
  return border_p(inner, pad_x, pad_y, none, stroke_name, line_width, radius)
end

fn outline(inner: Object, stroke_name: Color? = c"0.36,0.40,0.48", line_width: Number = 1, radius: Number = 8) -> Object
  return border(inner, 24, 16, stroke_name, line_width, radius)
end

fn/! code_l(text_value: String, language_name: String) -> Object
  let code = code_obj(text_value)
  code.language = language_name
  return code
end

fn code_in(text_value: String, language_name: String, left: Number, right: Number) -> Object
  let code = code_l(text_value, language_name)
  code.layout_x = left
  code.layout_right_inset = right
  code.wrap = WrapMode.on
  return code
end

fn code_panel(text_value: String, language_name: String, left: Number, right: Number, pad_x: Number, pad_y: Number) -> Object
  let code = code_in(text_value, language_name, left, right)
  let chrome = panel()
  chrome.layout_spacing_after = 34
  surround(chrome, code, pad_x, pad_y)
  return code
end

fn code_box(text_value: String, language_name: String, left: Number, right: Number, pad_x: Number, pad_y: Number, fill_name: Color?, stroke_name: Color?, line_width_name: Number, radius_name: Number) -> Object
  let code = code_in(text_value, language_name, left, right)
  let chrome = panel()
  box(chrome, fill_name, stroke_name, line_width_name, radius_name)
  chrome.layout_spacing_after = 34
  surround(chrome, code, pad_x, pad_y)
  return code
end

fn/! text(text_value: String) -> Object
  return body_obj(text_value)
end

fn/! tex(text_value: String, scale: Number = 1) -> Object
  let obj = tex_obj(text_value)
  obj.layout_x = 102
  obj.layout_right_inset = 102
  obj.wrap = WrapMode.on
  obj.math_scale = scale
  return obj
end

fn/! figure(text_value: String) -> Object
  let obj = fig_obj(text_value)
  obj.layout_x = 102
  obj.layout_right_inset = 102
  obj.wrap = WrapMode.on
  return obj
end

fn/! image(path_value: String, factor: Number = 1) -> Object
  let obj = scale(img_obj(path_value), factor)
  obj.layout_x = 102
  obj.layout_right_inset = 102
  obj.wrap = WrapMode.on
  require_asset_exists(obj)
  return obj
end

fn/! pdf(path_value: String, factor: Number = 1) -> Object
  let obj = scale(pdf_obj(path_value), factor)
  obj.layout_x = 102
  obj.layout_right_inset = 102
  obj.wrap = WrapMode.on
  require_asset_exists(obj)
  return obj
end

fn/! code(text_value: String, language_name: String = "python") -> Object
  let code = code_l(text_value, language_name)
  code.layout_x = 102
  code.layout_right_inset = 102
  code.wrap = WrapMode.on
  return code
end

fn/! code_file(path_value: String, language_name: String = "plain") -> Object
  return code(readlines(path_value), language_name)
end

fn/! note(text_value: String) -> Object
  let obj = note_obj(text_value)
  obj.layout_x = 120
  obj.layout_right_inset = 120
  obj.wrap = WrapMode.on
  return obj
end

fn/! citation(target: Object, number: Number, reference_text: String) -> Object
  let number_text = str(number)
  let marker = "[" ++ number_text ++ "]"
  let id = "citation:" ++ str(page_index(pagectx())) ++ ":" ++ number_text

  let ref = link(cite_obj(marker ++ " " ++ reference_text), id)
  ref.layout_x = 120
  ref.layout_right_inset = 90
  ref.wrap = WrapMode.on
  ~ ref.top == page.top - add(632, mul(sub(number, 1), 20))
  return ref
end

fn/! pageno() -> Object
  let page_no = pageno_obj()
  return page_no
end
