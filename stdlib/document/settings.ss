import std:theme/types as { Theme }
import std:layout/types as { LayoutPolicy, FitPolicy }

type PageSettings {
  theme: Theme? = none
  fit: FitPolicy = FitPolicy.warn
  notes: String = ""
  layout_h: LayoutPolicy = LayoutPolicy.left
  layout_h_center_offset: Number = 0
  layout_v: LayoutPolicy = LayoutPolicy.center
  layout_v_center_offset: Number = 0
  background_fill: Color? = none
}
