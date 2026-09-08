import std:themes/default as *

page ink_bounds
let left = text!("j")
left.text.size = 24
left.text.line_height = 36
left.text.font.family = "DejaVu Serif"
left.text.font.style = FontStyle.italic
~ left.left == page.left
~ left.top == page.top - 80

let right = text!("f")
right.text.size = 24
right.text.line_height = 36
right.text.font.family = "DejaVu Serif"
right.text.font.style = FontStyle.italic
~ right.left == page.left + 1270
~ right.top == page.top - 160

let padded = text!("j")
padded.text.size = 24
padded.text.line_height = 36
padded.text.font.family = "DejaVu Serif"
padded.text.font.style = FontStyle.italic
padded.chrome.pad_x = 10
padded.chrome.fill = c"#eeeeee"
~ padded.left == page.left
~ padded.top == page.top - 240
end
