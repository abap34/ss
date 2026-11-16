import std:layout/types as { Align, BlockLayout }
import std:graphics/paint/types as { BoxStyle }

type ImageStyle {
  scale: Number = 1
  align: Align? = none
  tint: Color? = none
  layout: BlockLayout = BlockLayout {}
  chrome: BoxStyle = BoxStyle {}
}
