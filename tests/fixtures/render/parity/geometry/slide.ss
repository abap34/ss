import std:themes/default as *

page geometry
pagectx().background_fill = c"0.96,0.97,0.99"
let card = place_on!(pagectx(), new("", "panel", "text"))
card.chrome.fill = c"0.89,0.94,0.97"
card.chrome.stroke = c"0.10,0.36,0.48"
card.chrome.line_width = 5
card.chrome.radius = 28
~ card.left == page.left + 120
~ card.right == page.right - 120
~ card.top == page.top - 140
~ card.bottom == page.bottom + 140
end
