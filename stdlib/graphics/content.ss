import std:theme as { theme_for }
import std:graphics/types as { VectorStyle, VectorStrokeStyle, MarkerStyle }

type PathShape {
  path: Path
  width: Number = 160
  height: Number = 100
  style: VectorStyle? = none
  stroke_only: Bool = false
  line_stroke: VectorStrokeStyle? = none
  marker_start: MarkerStyle? = none
  marker_end: MarkerStyle? = none
}

fn display(self: Placed<PathShape>) -> PathShape
  if self.value.stroke_only
    return self.value with { style = VectorStyle { stroke = self.value.style?.stroke ?? self.value.line_stroke ?? theme_for(self.page).path_shape.stroke } }
  end
  return self.value with { style = self.value.style ?? theme_for(self.page).path_shape }
end
