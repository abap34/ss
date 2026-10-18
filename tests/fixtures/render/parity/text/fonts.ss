import std:themes/default as *

page fonts
let heading = text!("Sans regular 24 pt", default_theme().body with {
  text.size = 24
  text.line_height = 30
  text.font.family = "sans-serif"
})
~ heading.left == page.left + 96
~ heading.top == page.top - 96

let bold = text!("Sans bold 52 pt", default_theme().body with {
  text.size = 52
  text.line_height = 60
  text.font.family = "sans-serif"
  text.font.weight = 700
})
~ bold.left == heading.left
~ bold.top == heading.bottom - 48

let mono = text!("Monospace 28 pt: fi -> 123", default_theme().body with {
  text.size = 28
  text.line_height = 36
  text.font.family = "monospace"
})
~ mono.left == heading.left
~ mono.top == bold.bottom - 48
end
