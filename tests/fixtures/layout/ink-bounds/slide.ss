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

let padded = code!("j", "plain", CodeBlockStyle {
  text = TextStyle {
    size = 24
    line_height = 36
    font = FontFace { family = "DejaVu Serif" style = FontStyle.italic }
    code_font = FontFace { family = "DejaVu Serif" style = FontStyle.italic }
  }
  chrome = ChromeStyle { pad_x = 10 fill = c"#eeeeee" }
})
~ padded.left == page.left
~ padded.top == page.top - 240
end
