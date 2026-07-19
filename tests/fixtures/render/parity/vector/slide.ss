import std:themes/default as *

page vector_image
let heading = h1!("Explicit SVG resource")
let picture = image!("asset.svg", 0.72)
~ heading.left == page.left + 96
~ heading.top == page.top - 72
~ picture.left == page.left + 208
~ picture.top == heading.bottom - 56
end
