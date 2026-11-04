import std:text/content as content
import std:text/style as { TextBlockStyle }
import std:layout/types as { LayoutStyle, WrapMode }

type Heading {
  title: String
}

fn/! heading(title: String) -> Heading = Heading { title = title }

fn display(self: Placed<Heading>) -> content::Text
  return content::Text {
    content = content::TextContent { source = self.value.title ++ " / page " ++ str(page_index(self.page)) }
    style = TextBlockStyle { layout = LayoutStyle { wrap = WrapMode.off } }
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
  let item = heading!("Second")
  ~ item.left == page.left + 48
end
