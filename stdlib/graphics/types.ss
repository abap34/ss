type LineCap = butt | round | square

type LineJoin = miter | round | bevel

type FillRule = nonzero | even_odd

type PaintSpace = local | page

type GradientSpread = pad | repeat | reflect

type FillKind = none | solid | linear | radial

type ConnectorAnchor = center | left | right | top | bottom

type ConnectorRoute = straight | horizontal_then_vertical | vertical_then_horizontal | curve

type PathVerb = move | line | quadratic | cubic | arc | close

type PathCommand = record {
  verb: PathVerb
  x: Number = 0
  y: Number = 0
  control_x: Number = 0
  control_y: Number = 0
  control2_x: Number = 0
  control2_y: Number = 0
  radius_x: Number = 0
  radius_y: Number = 0
  rotation: Number = 0
  large_arc: Bool = false
  clockwise: Bool = true
}

type VectorStrokeStyle = record {
  color: Color? = c"#4b5563"
  width: Number = 1.6
  cap: LineCap = LineCap.butt
  join: LineJoin = LineJoin.miter
  miter_limit: Number = 10
  dash: String = ""
  dash_offset: Number = 0
}

type LineStyle = record {
  start_x: Number = 0
  start_y: Number = 0.5
  end_x: Number = 1
  end_y: Number = 0.5
  stroke: VectorStrokeStyle = VectorStrokeStyle {}
  marker_start: MarkerStyle? = none
  marker_end: MarkerStyle? = none
}

type GradientDirection = record {
  start_x: Number = 0
  start_y: Number = 0.5
  end_x: Number = 1
  end_y: Number = 0.5
}

type PatternStyle = record {
  path: Path? = none
  cell_width: Number = 8
  cell_height: Number = 8
  xx: Number = 1
  yx: Number = 0
  xy: Number = 0
  yy: Number = 1
  x0: Number = 0
  y0: Number = 0
  rotation: Number = 0
  space: PaintSpace = PaintSpace.local
  fill: Color? = none
  stroke: VectorStrokeStyle? = none
}

type FillStyle = record {
  kind: FillKind = FillKind.none
  color: Color? = none
  color2: Color? = none
  start_x: Number = 0
  start_y: Number = 0
  start_radius: Number = 0
  end_x: Number = 1
  end_y: Number = 1
  end_radius: Number = 1
  spread: GradientSpread = GradientSpread.pad
  space: PaintSpace = PaintSpace.local
  rule: FillRule = FillRule.nonzero
  opacity: Number = 1
  pattern: PatternStyle? = none
}

type MarkerStyle = record {
  path: Path? = none
  width: Number = 10
  height: Number = 10
  fill: FillStyle = FillStyle {}
  stroke: VectorStrokeStyle = VectorStrokeStyle {}
}

type VectorStyle = record {
  fill: FillStyle = FillStyle {}
  stroke: VectorStrokeStyle = VectorStrokeStyle {}
}

type ConnectorStyle = record {
  source: Object? = none
  target: Object? = none
  source_anchor: ConnectorAnchor = ConnectorAnchor.right
  target_anchor: ConnectorAnchor = ConnectorAnchor.left
  route: ConnectorRoute = ConnectorRoute.straight
  curve: Number = 0.5
  stroke: VectorStrokeStyle = VectorStrokeStyle {
    color = c"#4b5563"
    width = 1.6
  }
  marker_start: MarkerStyle? = none
  marker_end: MarkerStyle? = none
}
