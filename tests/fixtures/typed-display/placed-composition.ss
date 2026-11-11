fn label!(content: String) -> Placed<Text>
  let item = text!(content)
  ~ item.width == 320
  return item
end

fn align_group!(item: Placed<Group>) -> Void
  ~ item.left == page.left + 80
  ~ item.top == page.top - 80
end

fn pair!<T>(a: Placed<T>, b: Placed<T>) -> Placed<Group<T, T>>
  return (a || b) with { gap = 24 }
end

type Badge {
  title: String
}

fn display(self: Placed<Badge>) -> Group<Text, Text>
  return text(self.value.title) // text("Detail")
end

page direct
  let row = (label!("Left") |=| label!("Right")) with { gap = 24 }
  ~ row.width == 664
  align_group!(row)
end

page natural
  let a = label!("First")
  let b = label!("Second")
  let row = (a || b) with { gap = 48 }
  align_group!(row)
end

page selected
  let items = select<Text>(pagectx())
  let g = group!(items)
  let a = text!("Selected A")
  let b = text!("Selected B")
  ~ a.left == page.left + 80
  ~ a.top == page.top - 80
  ~ b.left == a.right + 24
  ~ b.top == a.top
  let first_text = first(select<Text>(g))
  ~ first_text.width == 160
end

page ordered
  let a = text!("Paint A")
  let decoration = text!("Decoration")
  let b = text!("Paint B")
  let g = group!(b, a)
  let first_child = first(children(g))
  let first_text = first(select<Text>(g))
  ~ first_child.width == 180
  ~ first_text.width == 140
end

page expanded
  let badge = place!(Badge { title = "Title" })
  let g = group!(badge)
  let nested = first(children(g))
  let leaf = first(select<Text>(nested))
  ~ leaf.width == 240
  align_group!(g)
end

page nested
  let row = text!("Inner A") |=| text!("Inner B")
  let g = row |=| text!("Outer")
  ~ g.width == 900
  align_group!(g)
end

page flat
  let g = (text!("Flat A") |=| text!("Flat B") |=| text!("Flat C")) with { gap = 16 }
  ~ g.width == 900
  align_group!(g)
end

page empty
  let g = group!(filter(select<Text>(pagectx()), (item: Placed<Text>) |-> false))
  let other = group!()
end

page generic
  let groups = select<Group<Text, Text>>(pagectx())
  let g = pair!(text!("Generic A"), text!("Generic B"))
  let report = text!(str(selection_count(groups)))
end

page vertical
  let g = (text!("Upper") /=/ text!("Lower")) with { gap = 24 }
  ~ g.height == 400
  align_group!(g)
end

page natural_vertical
  let g = (text!("Natural upper") // text!("Natural lower")) with { gap = 48 }
  align_group!(g)
end

fn spacing!() -> Number
  let marker = text!("Spacing evaluated")
  return 48
end

page evaluation_order
  let row = (text!("Ordered left") || text!("Ordered right")) with { gap = spacing!() }
  align_group!(row)
end

page dependencies
  let ctx = pagectx()
  let spacing = ctx.layout_h_center_offset
  let row = (text!("Dependent left") || text!("Dependent right")) with { gap = spacing }
  ctx.layout_h_center_offset = 40
  align_group!(row)
end

page staged
  stages s { first second }
  let row = (text!("Staged left") || text!("Staged right")) with { gap = 16 + s * 8 }
  align_group!(row)
end

page zero_gap
  let row = (text!("Zero left") || text!("Zero right")) with { gap = 0 }
  align_group!(row)
end

page default_gap
  let row = (text!("Default left") || text!("Default right")) with {}
  align_group!(row)
end

page configured_nested
  let inner = (text!("Nested left") || text!("Nested right")) with { gap = 12 }
  let outer = (inner || text!("Nested outer")) with { gap = 48 }
  align_group!(outer)
end
