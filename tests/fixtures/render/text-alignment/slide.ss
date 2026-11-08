page centered
  let centered = text!(<<
Centered text inside a fixed width frame. Each wrapped line shares the same horizontal center.

Short line.

**Bold**, [linked](https://example.com), ==highlighted==, and ![star](fa:star) content stays together.
>>, default_text_style with {
    text.align = Align.center
    chrome.pad_x = 24
    chrome.pad_y = 16
    chrome.fill = c"#edf4ff"
  })
  ~ centered.left == page.left + 240
  ~ centered.top == page.top - 160
  ~ centered.width == 800
end

page right_aligned
  let right = text!(<<
# Centered heading

This paragraph is right aligned inside the text frame. It wraps when it reaches the available width.

Short paragraph.
>>, default_text_style with {
    text.align = Align.right
    headings.h1 = MarkdownHeadingStyle { text = TextStyle { size = 36 align = Align.center } }
    chrome.pad_x = 24
    chrome.pad_y = 16
    chrome.fill = c"#f0f8f1"
  })
  ~ right.left == page.left + 240
  ~ right.top == page.top - 160
  ~ right.width == 800
end
