import std:text/content as content

type Heading {
  title: String
}

fn place!<T>(value: T) -> Placed<T>
  return place_on!(pagectx(), value)
end

fn display(self: Placed<Heading>) -> content::Text
  return content::Text {
    content = self.value.title ++ " / page " ++ str(page_index(self.page))
  }
end

page first
  let input = Heading { title = "**Typed** heading" }
  let a = place!(input)
  let b = place!(input)
  ~ a.left == page.left + 48
  ~ b.left == a.right + 24
  ~ b.center_y == a.center_y
end

page second
  let heading = place!(Heading { title = "Second" })
  ~ heading.left == page.left + 48
end
