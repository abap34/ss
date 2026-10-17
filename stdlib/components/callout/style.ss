import std:internal/classes

type CalloutStyle {
  left_bracket: Bool = false
  stroke: Color? = c"#4b5563"
  line_width: Number = 1.6
  dash: String = ""
  marker_size: Number = 10
  bracket_width: Number = 24
  bracket_pad_x: Number = 14
  bracket_pad_y: Number = 8
  text: TextStyle = TextStyle {
    font = FontFace { family = "Helvetica" }
    code_font = FontFace { family = "monospace" }
    size = 17
    line_height = 25
    color = c"#374151"
  }
  chrome: ChromeStyle = ChromeStyle {
    fill = none
    stroke = c"#4b5563"
    line_width = 1
    radius = 6
    pad_x = 18
    pad_y = 12
  }
}
