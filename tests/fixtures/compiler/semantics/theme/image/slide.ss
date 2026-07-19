import std:themes/default as *

page ok
  image("asset.svg", 1, current_theme() with {
    image.chrome.stroke = c"#315ca8"
    image.chrome.pad_x = 17
  })
end
