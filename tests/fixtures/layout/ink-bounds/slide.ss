import std:themes/default as *

page ink_bounds
let left = text!("j", current_theme() with {
  body.text.size = 24
  body.text.line_height = 36
  body.text.font.family = "DejaVu Serif"
  body.text.font.style = FontStyle.italic
})
~ left.left == page.left
~ left.top == page.top - 80

let right = text!("f", current_theme() with {
  body.text.size = 24
  body.text.line_height = 36
  body.text.font.family = "DejaVu Serif"
  body.text.font.style = FontStyle.italic
})
~ right.left == page.left + 1270
~ right.top == page.top - 160

let padded = text!("j", current_theme() with {
  body.text.size = 24
  body.text.line_height = 36
  body.text.font.family = "DejaVu Serif"
  body.text.font.style = FontStyle.italic
})
padded.chrome.pad_x = 10
padded.chrome.fill = c"#eeeeee"
~ padded.left == page.left
~ padded.top == page.top - 240
end
