import std:themes/default as *
import std:text as text_api

page composition
let heading = place!(text_api::Text { content = "# Horizontal and vertical composition" })
~ heading.left == page.left + 72
~ heading.top == page.top - 48

let explanation = text_api::Text { content = <<
## Left column

A row can contain a vertical column.

- Each object keeps its own dimensions.
- The default gap is 32.
- Composition returns an ordinary group.
>> }

let figure = rectangle(
  360,
  210,
  vector_style(solid_fill(c"#dbeafe"), vector_stroke(c"#2563eb", 2))
)
let caption = text_api::Text { content = "The caption sits below the figure in the right column." }

let content = place!(explanation || (figure // caption))
~ content.width == 1000
~ content.height == 440
~ content.left == page.left + 110
~ content.top == page.top - 190
end

page composition_center
let heading = place!(text_api::Text { content = "# Equal composition" })
~ heading.left == page.left + 72
~ heading.top == page.top - 48

let explanation = text_api::Text { content = <<
## Left column

The two columns share a vertical center.

- The figure and caption form one column.
- Each column receives half the available width.
- Explicit position constraints take priority.
>> }

let figure = rectangle(
  484,
  204,
  vector_style(solid_fill(c"#dcfce7"), vector_stroke(c"#16a34a", 2))
)
let caption = text_api::Text { content = "The left column aligns with the center of this figure and caption together." }

let content = place!(explanation |=| (figure /=/ caption))
~ content.width == 1000
~ content.height == 440
~ content.left == page.left + 110
~ content.top == page.top - 190
end
