import std:themes/default as *

page ok
  image("asset.svg", 1, current_theme().image with {
    chrome.stroke = c"#315ca8"
    chrome.pad_x = 17
  })
end
