import std:themes/default as *

fn block!(label: String) -> Placed<Text>
  let item = text!(label, default_theme().body with {
    layout.spacing_after = 24
  })
  ~ item.left == page.left + 80
  ~ item.width == 620
  ~ item.height == 64
  return item
end

fn decoration!() -> Void
  let badge = place_on!(pagectx(), lab_obj("DRAFT"))
  ~ badge.width == 140
  ~ badge.height == 32
  ~ badge.right == page.right - 24
  ~ badge.top == page.top - 24

  let note = place_on!(pagectx(), lab_obj("Fixed note"))
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
foreach(pages(docctx()), (p: Page) |-> add_footer!(p))
end

fn add_footer!(p: Page) -> Void
  let footer = place_on!(p, text("Page anchors and automatic placement", TextBlockStyle {} with { text.size = 12 }))
  p ~ footer.left == p.left + 72
  p ~ footer.bottom == p.bottom + 20
end
