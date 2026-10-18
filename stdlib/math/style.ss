import std:layout/types as { LayoutStyle, WrapMode }
import std:graphics/paint/types as { ChromeStyle }
import std:math/types as { LatexStyle }

type LatexBlockStyle {
  latex: LatexStyle = LatexStyle {}
  layout: LayoutStyle = LayoutStyle { wrap = WrapMode.off }
  chrome: ChromeStyle = ChromeStyle {}
}
