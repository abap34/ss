import std:themes/default as *

page embedded_pdf
let picture = pdf_obj("asset.pdf")
picture.asset.scale = 0.72
picture.asset.pdf_page = 2
picture.asset.pdf_box = PdfPageBox.crop
picture.chrome.fill = none
picture.chrome.stroke = none
picture.chrome.line_width = 0
place_on!(pagectx(), picture)
~ picture.left == page.left + 312
~ picture.top == page.top - 168
end

page embedded_pdf_media
let picture = pdf_obj("asset.pdf")
picture.asset.scale = 0.72
picture.asset.pdf_page = 2
picture.asset.pdf_box = PdfPageBox.media
picture.chrome.fill = none
picture.chrome.stroke = none
picture.chrome.line_width = 0
place_on!(pagectx(), picture)
~ picture.left == page.left + 312
~ picture.top == page.top - 168
end
