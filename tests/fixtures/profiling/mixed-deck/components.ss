import "./theme" as theme_api
import std:text as native_text
import std:text/style as { TextBlockStyle }
import std:text/types as { TextParseMode }
import std:math/types as { LatexConfig }

const pale: Color = c"#f3f7fa"
const border: Color = c"#cadbe8"
const body_style: TextBlockStyle = theme_api::theme.body with {
  text.line_height = 38
  layout.spacing_after = 0
}
const title_style: TextBlockStyle = body_style with {
  text.size = 25
  text.line_height = 34
  text.font.weight = 700
  text.color = theme_api::accent
}

type Value001 { title: String label: String = "屋上" config: LatexConfig = LatexConfig {} }
type Value002 { title: String label: String = "新芽" config: LatexConfig = LatexConfig {} }
type Value003 { title: String label: String = "観客" config: LatexConfig = LatexConfig {} }

fn item004<T>(item075: Placed<T>) -> Number
  return number_of(item075, select<T>(item075.document)) ?? 0
end

fn item005<T>(item075: Placed<T>) -> String
  return item075.value.label ++ " " ++ str(item004(item075))
end

fn display(self: Placed<Value001>) -> Text
  return native_text::text(item005(self) ++ "　" ++ self.value.title, title_style, self.value.config)
end

fn display(self: Placed<Value002>) -> Text
  return native_text::text(item005(self) ++ "　" ++ self.value.title, title_style, self.value.config)
end

fn display(self: Placed<Value003>) -> Text
  return native_text::text(item005(self) ++ "　" ++ self.value.title, title_style, self.value.config)
end

fn item006!<T>(title: T, content: String, width: Number = 1088) -> Placed<Group<PathShape, PathShape, T, Text>>
  ;; Anonymous fixture note.
  let item007 = rectangle!(width, 1, vector_style(no_fill(), solid_stroke(border, 1)))
  let item008 = rectangle!(width, 1, vector_style(solid_fill(pale), no_stroke()))
  let heading = place!(title)
  let body = theme_api::text!(content, body_style)
  ~ item008.left == item007.left
  ~ item007.top == heading.top + 12
  ~ item007.bottom == body.bottom - 22
  ~ item008.top == item007.top
  ~ item008.bottom == heading.bottom - 12
  ~ heading.left == item007.left + 28
  ~ heading.width == width - 56
  ~ body.left == heading.left
  ~ body.top == heading.bottom - 30
  ~ body.width == width - 56
  return group!(item007, item008, heading, body)
end

fn block!(content: String, width: Number = 1088) -> Placed<Group<PathShape, Text>>
  let item007 = rectangle!(width, 1, vector_style(no_fill(), solid_stroke(border, 1)))
  let body = theme_api::text!(content, body_style)
  ~ item007.top == body.top + 22
  ~ item007.bottom == body.bottom - 22
  ~ body.left == item007.left + 28
  ~ body.width == width - 56
  return group!(item007, body)
end

fn item011!(title: String, content: String, width: Number = 1088) -> Placed<Group<PathShape, PathShape, Value001, Text>>
  return item006!(Value001 { title = title config = theme_api::latex_config }, content, width)
end

fn item012!(title: String, content: String, width: Number = 1088) -> Placed<Group<PathShape, PathShape, Value002, Text>>
  return item006!(Value002 { title = title config = theme_api::latex_config }, content, width)
end

fn item013!(title: String, content: String, width: Number = 1088) -> Placed<Group<PathShape, PathShape, Value003, Text>>
  return item006!(Value003 { title = title config = theme_api::latex_config }, content, width)
end

fn item014<T>(block: Placed<Group<PathShape, PathShape, T, Text>>) -> Number
  return item004(first(select<T>(block)))
end

fn item015<T>(block: Placed<Group<PathShape, PathShape, T, Text>>) -> String
  return item005(first(select<T>(block)))
end

fn item016(document: Document, level: Number) -> Selection<Placed<Heading>>
  return filter(select<Heading>(document), (item075: Placed<Heading>) |-> item075.value.level == level)
end

fn item017(target: Page, document: Document) -> Selection<Placed<Heading>>
  let item018 = item016(document, 1)
  let item019 = item016(document, 2)
  let item020 = page_index(target)
  let item021 = filter(item018, (item075: Placed<Heading>) |-> page_index(item075.page) <= item020)
  if selection_empty(item021)
    return item019 - item019
  end
  let item022 = filter(item018, (item075: Placed<Heading>) |-> page_index(item075.page) > item020)
  let item023 = fold(item021, 0, (bound: Number, item075: Placed<Heading>) |-> max(bound, page_index(item075.page)))
  let item024 = fold(item022, page_count(document) + 1, (bound: Number, item075: Placed<Heading>) |-> min(bound, page_index(item075.page)))
  let item025 = filter(item019, (item075: Placed<Heading>) |-> page_index(item075.page) >= item023)
  return filter(item025, (item075: Placed<Heading>) |-> page_index(item075.page) < item024)
end

fn item026(items: Selection<Placed<Heading>>) -> String
  return join(items, "
", (item075: Placed<Heading>) |-> str(number_of(item075, items) ?? 0) ++ ". " ++ item075.value.title)
end

fn item027!(items: Selection<Placed<Heading>>, style: TextBlockStyle = theme_api::theme.body) -> Placed<Text>
  return theme_api::text!(item026(items), style)
end

fn item028!() -> Placed<Text>
  return item027!(item016(docctx(), 1), theme_api::theme.h2 with { text.parse = TextParseMode.block text.line_height = 50 })
end

fn item029!() -> Placed<Text>
  return item027!(item017(pagectx(), docctx()), theme_api::theme.body with { text.size = 26 text.line_height = 42 })
end

fn/! item030(style: TextBlockStyle = theme_api::theme.body) -> Text
  return theme_api::text("→", style)
end

fn/! item031(content: String, style: TextBlockStyle = theme_api::theme.body) -> Text
  return theme_api::text(content, style with { text.size = 20 text.line_height = 30 })
end
