import std:core/prelude as *

document
  hflow_doc(LayoutPolicy.center)
end

fn box(label: String, width: Number, height: Number) -> Object
  let item = new(label, "body", "text")
  ~ item.width == width
  ~ item.height == height
  return item
end

page centered_column
  let description = place!(box("Centered column", 320, 80))
  let picture = image!("picture.svg", 1)
  let example = place!(box("A wider neighboring column", 360, 280))
  let caption = place!(box("Example caption", 200, 40))
  let row = (description // picture) |=| (example // caption)
  ~ row.left == page.left + 80
  ~ row.top == page.top - 100
  ~ row.width == 1120
end

page left_column
  hflow(LayoutPolicy.left)
  let description = place!(box("Left-aligned column", 320, 80))
  let picture = image!("picture.svg", 1)
  let example = place!(box("A wider neighboring column", 360, 280))
  let caption = place!(box("Example caption", 200, 40))
  let row = (description // picture) |=| (example // caption)
  ~ row.left == page.left + 80
  ~ row.top == page.top - 100
  ~ row.width == 1120
end
