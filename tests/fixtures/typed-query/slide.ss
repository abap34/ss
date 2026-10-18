import std:text/content as native
type Heading { title: String }
type Wrapped { content: Heading }
type Toc {}
fn/! heading(title: String) -> Heading = Heading { title = title }
fn/! wrapped(title: String) -> Wrapped = Wrapped { content = heading(title) }
fn/! toc() -> Toc = Toc {}
fn display(self: Placed<Heading>) -> native::Text
  return native::Text { content = self.value.title }
end
fn display(self: Placed<Wrapped>) -> Heading = self.value.content
fn all<T>(scope: Document) -> Selection<Placed<T>> = select<T>(scope)
fn display(self: Placed<Toc>) -> native::Text
  let all_headings = all<Heading>(self.document)
  let headings = (all_headings | all_headings) - select<Heading>(self)
  return native::Text { content = join(headings, ", ", (h: Placed<Heading>) |-> h.value.title) }
end
page contents
  toc!()
end
page body
  let a = wrapped!("First")
  let b = heading!("Second")
  let heading: Placement = first(children(a))
  let text: Placement = first(descendants(heading))
  ~ text.left == page.left + 48
end
