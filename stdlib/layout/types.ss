type Align = left | center | right

type LayoutPolicy = left | right | top | top_flow | center | center_stack

type SplitAxis = none | horizontal | vertical

type WrapMode = on | off

type FitPolicy = warn | error | ignore

type LayoutStyle = record {
  font_size: Number? = none
  line_height: Number? = none
  spacing_after: Number = 32
  x: Number = 96
  right_inset: Number = 96
  wrap: WrapMode = WrapMode.on
  fit: FitPolicy = FitPolicy.warn
}
