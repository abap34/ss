import std:themes/academic as *

page ok
  toc!("Contents", current_theme().toc with {
    chrome.fill = c"#eef3f9"
    chrome.pad_y = 11
  })
end
