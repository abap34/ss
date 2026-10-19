enum Align { left center right }

enum LayoutPolicy { left right top top_flow center center_stack }

enum WrapMode { on off }

enum FitPolicy { warn error ignore }

type LayoutStyle {
  font_size: Number? = none
  line_height: Number? = none
  spacing_after: Number = 32
  x: Number = 96
  right_inset: Number = 96
  wrap: WrapMode = WrapMode.on
  fit: FitPolicy = FitPolicy.warn
}

;; Per-placement composition inputs, independent of immutable child values.
type GroupLayout {
  gap: Number = 32
}
