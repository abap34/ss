import std:assets as assets
import std:text as text_api

type Sheet {
  content: assets::Pdf
}

fn display(self: Placed<Sheet>) -> assets::Pdf = self.value.content

const content: assets::Pdf = assets::Pdf {
  path = "asset.pdf"
  style = assets::AssetBlockStyle {} with {
    asset.scale = 0.8
    asset.pdf_page = 2
    chrome.pad_x = 8
    chrome.pad_y = 8
    chrome.stroke = c"#334155"
  }
}

page boxes
  let unused = assets::Pdf { path = "unplaced.pdf" }
  let title = place!(text_api::Text { content = "# PDF crop and media boxes" })
  let crop = place!(content)
  let media = place!(content with { style.asset.pdf_box = assets::PdfPageBox.media })
  ~ title.left == page.left + 64
  ~ title.top == page.top - 48
  ~ crop.left == title.left
  ~ crop.top == title.bottom - 32
  ~ media.left == crop.right + 48
  ~ media.top == crop.top
end

page first_sheet
  let title = place!(text_api::Text { content = "# First PDF page returned by a display" })
  let wrapped = place!(Sheet { content = content with { style.asset.pdf_page = 1 } })
  ~ title.left == page.left + 64
  ~ title.top == page.top - 48
  ~ wrapped.left == title.left
  ~ wrapped.top == title.bottom - 32
end
