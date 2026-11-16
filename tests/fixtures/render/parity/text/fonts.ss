import std:themes/default as *

page fonts
let heading = text!("Sans regular 24 pt", default_theme().text with {
  size = 24
  line_height = 30
  font.family = "sans-serif"
})
~ heading.left == page.left + 96
~ heading.top == page.top - 96

let bold = text!("Sans bold 52 pt", default_theme().text with {
  size = 52
  line_height = 60
  font.family = "sans-serif"
  font.weight = 700
})
~ bold.left == heading.left
~ bold.top == heading.bottom - 48

let mono = text!("Monospace 28 pt: fi -> 123", default_theme().text with {
  size = 28
  line_height = 36
  font.family = "monospace"
})
~ mono.left == heading.left
~ mono.top == bold.bottom - 48
end
