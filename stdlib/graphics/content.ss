import std:graphics/types as { VectorStyle, MarkerStyle }

type PathShape {
  path: Path
  width: Number = 160
  height: Number = 100
  style: VectorStyle = VectorStyle {}
  marker_start: MarkerStyle? = none
  marker_end: MarkerStyle? = none
}
