type BottomRule {
  color: Color? = none
  width: Number = 1
  offset: Number = -2
}

type BoxStyle {
  fill: Color? = none
  stroke: Color? = none
  line_width: Number = 1
  radius: Number = 10
  pad_x: Number = 0
  pad_y: Number = 0
  bottom_rule: BottomRule = BottomRule {}
}
