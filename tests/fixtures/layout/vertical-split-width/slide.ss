import std:core/prelude as *

page rows
let title = text!("Vertical splits use the available page width")
~ title.top == page.top - 64

let first = text("First row, left column") |=| text("First row, right column")
let second = text("Second row, left column") |=| text("Second row, right column")
let content = first /=/ second
content.chrome.pad_x = 16
~ content.height == 400
~ content.top == page.top - 160
place!(content)
end
