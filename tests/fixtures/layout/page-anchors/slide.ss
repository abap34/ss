import std:themes/default as *

fn/! block(label: String) -> Object
  let item = text(label)
  ~ item.left == page.left + 80
  ~ item.width == 620
  ~ item.height == 64
  item.layout.spacing_after = 24
  return item
end

fn decoration!() -> Void
  let badge = place!(lab_obj("DRAFT"))
  ~ badge.width == 140
  ~ badge.height == 32
  ~ badge.right == page.right - 24
  ~ badge.top == page.top - 24

  let note = place!(lab_obj("Fixed note"))
  ~ note.width == 200
  ~ note.height == 32
  ~ note.right == badge.right
  ~ note.top == badge.bottom - 16
end

page baseline
vflow(LayoutPolicy.top)
block!("First block")
block!("Second block")
end

page anchored
vflow(LayoutPolicy.top)
decoration!()
block!("First block")
block!("Second block")
end

page centered
vflow(LayoutPolicy.center)
decoration!()
block!("First block")
block!("Second block")
end

document
pagenos!()
footers!("Page anchors and automatic placement")
end
