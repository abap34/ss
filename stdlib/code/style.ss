import std:text/types as { FontFace }
import std:graphics/paint/types as { BoxStyle }
import std:code/types as { CodeColors }

type CodeAppearance {
  font: FontFace = FontFace { family = "monospace" }
  size: Number = 16
  line_height: Number? = none
  chrome: BoxStyle = BoxStyle { pad_x = 12 pad_y = 10 }
  line_highlight_fill: Color? = c"#fff2a8"
  colors: CodeColors = CodeColors {}
}
