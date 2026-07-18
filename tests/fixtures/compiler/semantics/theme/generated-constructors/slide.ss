import std:themes/default as *

document
  let theme = current_theme() with {
    generated.pageno.text.size = 17
    generated.footer.text.size = 18
    generated.watermark.text.size = 19
  }
  pagenos!(none, theme)
  footers!("footer", theme)
  watermark!("watermark", theme)
end

page ok
end
