import std:themes/default as *

page raster_image
let heading = heading!("Raster image", 1, default_theme().text)
let picture = image!("asset.png", ImageStyle {} with { scale = 0.7 })
~ heading.left == page.left + 96
~ heading.top == page.top - 72
~ picture.left == page.left + 256
~ picture.top == heading.bottom - 56
end
