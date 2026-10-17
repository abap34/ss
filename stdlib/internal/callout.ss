import std:components/callout/style
import std:internal/objects as objects
import std:layout as layout
import std:graphics/connectors as connectors
import std:graphics/paint as fills
import std:graphics as shapes

fn/! callout_text(text_value: String, style: CalloutStyle) -> Object
  let obj = objects::body_obj(text_value)
  obj.text = style.text
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
  let obj = objects::panel_obj()
  obj.chrome = ChromeStyle { fill = color_name stroke = none line_width = 0 radius = thickness / 2 }
  obj.layout.font_size = 1
  obj.layout.line_height = 1
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

fn callout_connector_style(style: CalloutStyle) -> ConnectorStyle
  let marker_color = style.stroke ?? c"#4b5563"
  return ConnectorStyle {
    source_anchor = ConnectorAnchor.right
    target_anchor = ConnectorAnchor.left
    route = ConnectorRoute.straight
    stroke = fills::vector_stroke(style.stroke, style.line_width, LineCap.round, LineJoin.round, style.dash)
    marker_end = shapes::marker_arrow_open(style.marker_size, marker_color, style.line_width)
  }
end

fn/! marked_callout_text(text_value: String, style: TextStyle) -> Object
  let obj = objects::body_obj(text_value)
  obj.text = style
  obj.layout = LayoutStyle {
    spacing_after = 0
    x = 0
    right_inset = 0
    wrap = WrapMode.off
    fit = FitPolicy.warn
  }
  return obj
end
