import std:text as text_api

const a: text_api::Text = text_api::Text { content = "Input" }
const b: text_api::Text = text_api::Text { content = "Processing" }
const c: text_api::Text = text_api::Text { content = "Output" }
const row: Group<text_api::Text, text_api::Text> = (a || b) with { gap = 48 }

page natural_row
  let item = place!(row)
  ~ item.left == page.left + 80
  ~ item.top == page.top - 80
end

page natural_column
  let item = place!((a // b) with { gap = 24 })
  ~ item.left == page.left + 80
  ~ item.top == page.top - 80
end

page equal_row
  let item = place!((a |=| b |=| c) with { gap = 24 })
  ~ item.left == page.left + 80
  ~ item.top == page.top - 80
  ~ item.width == 900
end

page equal_column
  let item = place!((a /=/ b) with { gap = 24 })
  ~ item.left == page.left + 80
  ~ item.top == page.top - 80
  ~ item.width == 900
  ~ item.height == 300
end

page nested
  let item = place!((row |=| (b // c)) with { gap = 40 })
  ~ item.left == page.left + 80
  ~ item.top == page.top - 80
  ~ item.width == 900
end

page reuse
  let item = place!(row with { gap = 96 })
  ~ item.left == page.left + 80
  ~ item.top == page.top - 80
end
