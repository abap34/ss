import std:themes/academic as *

page ok
  toc!("Contents", current_theme() with {
    toc.chrome.fill = c"#eef3f9"
    toc.chrome.pad_y = 11
  })
end
