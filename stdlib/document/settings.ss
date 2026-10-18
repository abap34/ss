import std:layout/types as { LayoutPolicy }

type PageSettings {
  layout_h: LayoutPolicy = LayoutPolicy.left
  layout_h_center_offset: Number = 0
  layout_v: LayoutPolicy = LayoutPolicy.center
  layout_v_center_offset: Number = 0
  background_fill: Color? = none
}
