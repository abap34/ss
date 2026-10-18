import std:themes/default as *

page ink_bounds
let left = text!("j", default_theme().body with {
  text.size = 24
  text.line_height = 36
  text.font.family = "DejaVu Serif"
  text.font.style = FontStyle.italic
})
~ left.left == page.left
~ left.top == page.top - 80

let right = text!("f", default_theme().body with {
  text.size = 24
  text.line_height = 36
  text.font.family = "DejaVu Serif"
  text.font.style = FontStyle.italic
})
~ right.left == page.left + 1270
~ right.top == page.top - 160

let padded = body_obj!("j")
padded.text = TextStyle {
  size = 24
  line_height = 36
  font = FontFace { family = "DejaVu Serif" style = FontStyle.italic }
}
padded.chrome.pad_x = 10
padded.chrome.fill = c"#eeeeee"
~ padded.left == page.left
~ padded.top == page.top - 240
end
