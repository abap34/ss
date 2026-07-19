import std:themes/default as *

page fonts
let heading = text!("Sans regular 24 pt")
heading.text.size = 24
heading.text.line_height = 30
heading.text.font.family = "sans-serif"
~ heading.left == page.left + 96
~ heading.top == page.top - 96

let bold = text!("Sans bold 52 pt")
bold.text.size = 52
bold.text.line_height = 60
bold.text.font.family = "sans-serif"
bold.text.font.weight = 700
~ bold.left == heading.left
~ bold.top == heading.bottom - 48

let mono = text!("Monospace 28 pt: fi -> 123")
mono.text.size = 28
mono.text.line_height = 36
mono.text.font.family = "monospace"
~ mono.left == heading.left
~ mono.top == bold.bottom - 48
end
