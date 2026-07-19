import std:core/classes as classes
import std:core/fills as fills
import std:core/objects as objects
import std:core/shapes as shapes

fn default_connector_style() -> ConnectorStyle
  return ConnectorStyle {
    stroke = fills::vector_stroke(c"#4b5563", 1.6, LineCap.round, LineJoin.round)
    marker_end = shapes::marker_arrow_open(10, c"#4b5563", 1.6)
  }
end

fn/! connector(source: Object, target: Object, style: ConnectorStyle = default_connector_style()) -> Object
  let obj = objects::connector_obj()
  obj.connector = style with {
    source = source
    target = target
  }
  return obj
end

fn/! connect(source: Object, target: Object, style: ConnectorStyle = default_connector_style()) -> Object
  return connector(source, target, style)
end

fn/! connect_straight(source: Object, target: Object, style: ConnectorStyle = default_connector_style()) -> Object
  return connector(source, target, style with { route = ConnectorRoute.straight })
end

fn/! connect_orthogonal(source: Object, target: Object, style: ConnectorStyle = default_connector_style()) -> Object
  return connector(source, target, style with { route = ConnectorRoute.horizontal_then_vertical })
end

fn/! connect_curve(source: Object, target: Object, style: ConnectorStyle = default_connector_style()) -> Object
  return connector(source, target, style with { route = ConnectorRoute.curve })
end

fn/! straight_connector(source: Object, target: Object, stroke_value: VectorStrokeStyle = VectorStrokeStyle { color = c"#4b5563" width = 1.6 }) -> Object
  return connector(source, target, ConnectorStyle {
    route = ConnectorRoute.straight
    stroke = stroke_value
  })
end

fn/! horizontal_connector(source: Object, target: Object, stroke_value: VectorStrokeStyle = VectorStrokeStyle { color = c"#4b5563" width = 1.6 }) -> Object
  return connector(source, target, ConnectorStyle {
    route = ConnectorRoute.horizontal_then_vertical
    stroke = stroke_value
  })
end

fn/! vertical_connector(source: Object, target: Object, stroke_value: VectorStrokeStyle = VectorStrokeStyle { color = c"#4b5563" width = 1.6 }) -> Object
  return connector(source, target, ConnectorStyle {
    source_anchor = ConnectorAnchor.bottom
    target_anchor = ConnectorAnchor.top
    route = ConnectorRoute.vertical_then_horizontal
    stroke = stroke_value
  })
end

fn/! curve_connector(source: Object, target: Object, stroke_value: VectorStrokeStyle = VectorStrokeStyle { color = c"#4b5563" width = 1.6 }) -> Object
  return connector(source, target, ConnectorStyle {
    route = ConnectorRoute.curve
    stroke = stroke_value
  })
end

fn/! arrow_connector(source: Object, target: Object, route: ConnectorRoute = ConnectorRoute.straight, source_anchor: ConnectorAnchor = ConnectorAnchor.right, target_anchor: ConnectorAnchor = ConnectorAnchor.left, stroke_value: VectorStrokeStyle = VectorStrokeStyle { color = c"#4b5563" width = 1.6 }, marker_size: Number = 10) -> Object
  let color_name = stroke_value.color ?? c"#4b5563"
  return connector(source, target, ConnectorStyle {
    source_anchor = source_anchor
    target_anchor = target_anchor
    route = route
    stroke = stroke_value
    marker_end = shapes::marker_arrow_open(marker_size, color_name, stroke_value.width)
  })
end

fn/! double_arrow_connector(source: Object, target: Object, route: ConnectorRoute = ConnectorRoute.straight, source_anchor: ConnectorAnchor = ConnectorAnchor.right, target_anchor: ConnectorAnchor = ConnectorAnchor.left, stroke_value: VectorStrokeStyle = VectorStrokeStyle { color = c"#4b5563" width = 1.6 }, marker_size: Number = 10) -> Object
  let color_name = stroke_value.color ?? c"#4b5563"
  let marker = shapes::marker_arrow_open(marker_size, color_name, stroke_value.width)
  return connector(source, target, ConnectorStyle {
    source_anchor = source_anchor
    target_anchor = target_anchor
    route = route
    stroke = stroke_value
    marker_start = marker
    marker_end = marker
  })
end
