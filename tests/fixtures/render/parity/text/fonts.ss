import std:themes/default as *

page fonts
let heading = text!("Sans regular 24 pt", current_theme() with {
  body.text.size = 24
  body.text.line_height = 30
  body.text.font.family = "sans-serif"
})
~ heading.left == page.left + 96
~ heading.top == page.top - 96

let bold = text!("Sans bold 52 pt", current_theme() with {
  body.text.size = 52
  body.text.line_height = 60
  body.text.font.family = "sans-serif"
  body.text.font.weight = 700
})
~ bold.left == heading.left
~ bold.top == heading.bottom - 48

let mono = text!("Monospace 28 pt: fi -> 123", current_theme() with {
  body.text.size = 28
  body.text.line_height = 36
  body.text.font.family = "monospace"
})
~ mono.left == heading.left
~ mono.top == bold.bottom - 48
end
