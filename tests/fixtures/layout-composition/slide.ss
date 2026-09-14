import std:themes/default as *

page composition
vflow(LayoutPolicy.top)
head! "Horizontal and vertical composition: top alignment"

let explanation = text <<
## Left column

A row can contain a vertical column.

- Each object keeps its own dimensions.
- The default gap is 32.
- Composition returns an ordinary group.
>>
~ explanation.width == 480

let figure = rounded_rectangle(
  360,
  210,
  0.12,
  vector_style(solid_fill(c"#dbeafe"), vector_stroke(c"#2563eb", 2))
)
let caption = text("The caption sits below the figure in the right column.")
~ caption.width == 360

let content = explanation || (figure // caption)
place!(content)
~ content.left == page.left + 110
~ content.top == page.top - 190
end

page composition_center
vflow(LayoutPolicy.center)
head! "Horizontal and vertical composition: center alignment"

let explanation = text <<
## Left column

The two columns share a vertical center.

- The figure and caption form one column.
- Object dimensions stay unchanged.
- Explicit position constraints take priority.
>>
~ explanation.width == 480

let figure = rounded_rectangle(
  360,
  210,
  0.12,
  vector_style(solid_fill(c"#dcfce7"), vector_stroke(c"#16a34a", 2))
)
let caption = text("The left column aligns with the center of this figure and caption together.")
~ caption.width == 360

let content = explanation || (figure // caption)
place!(content)
~ content.left == page.left + 110
~ content.top == page.top - 190
end
