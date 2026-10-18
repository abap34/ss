import std:assets as { pdf!, AssetBlockStyle, AssetStyle, PdfPageBox }
import std:graphics/paint/types as { ChromeStyle }

page embedded_pdf
let picture = pdf!("asset.pdf", AssetBlockStyle {
  asset = AssetStyle { scale = 0.72 pdf_page = 2 pdf_box = PdfPageBox.crop }
  chrome = ChromeStyle { fill = none stroke = none line_width = 0 }
})
~ picture.left == page.left + 312
~ picture.top == page.top - 168
end

page embedded_pdf_media
let picture = pdf!("asset.pdf", AssetBlockStyle {
  asset = AssetStyle { scale = 0.72 pdf_page = 2 pdf_box = PdfPageBox.media }
  chrome = ChromeStyle { fill = none stroke = none line_width = 0 }
})
~ picture.left == page.left + 312
~ picture.top == page.top - 168
end
