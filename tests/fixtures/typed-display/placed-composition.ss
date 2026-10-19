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
  return a || b
end

type Badge {
  title: String
}

fn display(self: Placed<Badge>) -> Group<Text, Text>
  return text(self.value.title) // text("Detail")
end

page direct
  let row = label!("Left") |=| label!("Right")
  row.layout.gap = 24
  ~ row.width == 664
  align_group!(row)
end

page natural
  let a = label!("First")
  let b = label!("Second")
  let row = a || b
  row.layout = GroupLayout { gap = 48 }
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
  let g = text!("Flat A") |=| text!("Flat B") |=| text!("Flat C")
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
  let g = text!("Upper") /=/ text!("Lower")
  ~ g.height == 400
  align_group!(g)
end

page natural_vertical
  let g = text!("Natural upper") // text!("Natural lower")
  g.layout.gap = 48
  align_group!(g)
end
