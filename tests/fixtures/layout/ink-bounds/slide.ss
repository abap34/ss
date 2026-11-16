import std:themes/default as *

page ink_bounds
let left = text!("j", default_theme().text with {
  layout.wrap = WrapMode.off
  size = 24
  line_height = 36
  font.family = "DejaVu Serif"
  font.style = FontStyle.italic
})
~ left.left == page.left
~ left.top == page.top - 80

let right = text!("f", default_theme().text with {
  layout.wrap = WrapMode.off
  size = 24
  line_height = 36
  font.family = "DejaVu Serif"
  font.style = FontStyle.italic
})
~ right.left == page.left + 1270
~ right.top == page.top - 160

let padded = code!("j", "plain", default_text_style with {
  code.size = 24
  code.line_height = 36
  code.font = FontFace { family = "DejaVu Serif" style = FontStyle.italic }
  code.chrome.pad_x = 10
  code.chrome.fill = c"#eeeeee"
})
~ padded.left == page.left
~ padded.top == page.top - 240
end
