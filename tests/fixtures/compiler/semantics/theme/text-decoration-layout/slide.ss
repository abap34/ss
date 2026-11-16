import std:themes/default as *

page ok
  text!("Heading", default_theme().text with {
    layout.left_inset = 137
    chrome.bottom_rule.color = c"#a1264f"
    chrome.bottom_rule.width = 3
  })
end
