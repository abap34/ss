import std:assets as assets
import std:text as text_api

type Picture {
  image: assets::Image
}

fn display(self: Placed<Picture>) -> assets::Image
  return self.value.image
end

const picture: assets::Image = assets::Image {
  path = "../layout/practical/diagram.svg"
  style = assets::AssetBlockStyle {} with {
    asset.scale = 0.5
    chrome.pad_x = 8
    chrome.pad_y = 8
    chrome.stroke = c"#334155"
    chrome.radius = 8
  }
}

page sizes
  let title = place!(text_api::Text { content = "# Immutable image inputs" })
  let half = place!(picture)
  let quarter = place!(picture with { style.asset.scale = 0.25 })
  ~ title.left == page.left + 64
  ~ title.top == page.top - 48
  ~ half.left == page.left + 64
  ~ half.top == title.bottom - 32
  ~ quarter.left == half.right + 48
  ~ quarter.top == half.top
end

page reused
  let title = place!(text_api::Text { content = "# Image returned by a user display" })
  let wrapped = place!(Picture { image = picture })
  ~ title.left == page.left + 64
  ~ title.top == page.top - 48
  ~ wrapped.left == page.left + 64
  ~ wrapped.top == title.bottom - 32
end
