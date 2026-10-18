import std:assets as assets
import std:text as text_api

const symbol: assets::Icon = assets::Icon {
  source = "fa-solid:star"
  style = assets::AssetBlockStyle {} with { asset.tint = c"#2563eb" }
}

type Badge { label: String symbol: assets::Icon }
fn display(self: Placed<Badge>) -> Group<assets::Icon, text_api::Text>
  return (self.value.symbol // text_api::Text { content = self.value.label }) with { gap = 20 }
end

page styles
  let title = place!(text_api::Text { content = "# Immutable icons" })
  let original = place!(symbol)
  let changed = place!(symbol with { source = "fa-solid:heart" style.asset.tint = c"#db2777" style.asset.scale = 1.5 })
  let constrained = place!(symbol)
  ~ title.left == page.left + 64
  ~ title.top == page.top - 48
  ~ original.left == title.left
  ~ original.top == title.bottom - 48
  ~ changed.left == original.right + 64
  ~ changed.top == original.top
  ~ constrained.left == changed.right + 64
  ~ constrained.top == original.top
  ~ constrained.width == 36
  ~ constrained.height == 36
end

page reused
  let title = place!(text_api::Text { content = "# Reusable components" })
  let count = place!(text_api::Text { content = "Icons: " ++ str(selection_count(select<assets::Icon>(pagectx()))) })
  let badges = place!((
    Badge { label = "Original" symbol = symbol } ||
    Badge { label = "Independent copy" symbol = symbol }
  ) with { gap = 64 })
  ~ title.left == page.left + 64
  ~ title.top == page.top - 48
  ~ count.left == title.left
  ~ count.top == title.bottom - 32
  ~ badges.left == title.left
  ~ badges.top == count.bottom - 48
end
