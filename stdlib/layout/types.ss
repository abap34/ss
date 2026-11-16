enum Align { left center right }

enum LayoutPolicy { left right top top_flow center center_stack }

enum WrapMode { on off }

enum FitPolicy { warn error ignore }

type TextLayout {
  spacing_after: Number = 32
  left_inset: Number = 96
  right_inset: Number = 96
  wrap: WrapMode = WrapMode.on
}

type BlockLayout {
  spacing_after: Number = 32
  left_inset: Number = 96
  right_inset: Number = 96
}
