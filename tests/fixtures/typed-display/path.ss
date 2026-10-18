import std:graphics as graphics
import std:graphics/path as paths
import std:graphics/paint as paint
import std:text as text_api

const outline: Path = path(
  paths::move_to(0.1, 0.1), paths::line_to(0.9, 0.1),
  paths::line_to(0.9, 0.9), paths::line_to(0.1, 0.9), paths::close_path()
)
const shape: graphics::PathShape = graphics::PathShape {
  path = outline
  width = 180
  height = 120
  style = graphics::VectorStyle {
    fill = paint::solid_fill(c"#dbeafe")
    stroke = paint::vector_stroke(c"#2563eb", 3)
  }
}

type Diagram { label: String shape: graphics::PathShape }
fn display(self: Placed<Diagram>) -> Group<text_api::Text, graphics::PathShape>
  return (text_api::Text { content = self.value.label } // self.value.shape) with { gap = 20 }
end

page normal
  let title = place!(text_api::Text { content = "# Immutable vector paths" })
  let original = place!(shape)
  let changed = place!(shape with { width = 240 style.fill = paint::solid_fill(c"#dcfce7") style.stroke.color = c"#16a34a" })
  let curved = place!(graphics::PathShape {
    path = path(paths::move_to(0.1, 0.8), paths::cubic_to(0.2, 0.1, 0.7, 0.9, 0.9, 0.2))
    width = 200 height = 120
    marker_start = graphics::MarkerStyle {
      path = path(paths::move_to(1, 0.5), paths::arc_to(0.5, 0.5, 0, false, true, 0, 0.5), paths::arc_to(0.5, 0.5, 0, false, true, 1, 0.5), paths::close_path())
      fill = paint::solid_fill(c"#7c3aed") stroke = paint::no_stroke()
    }
    marker_end = graphics::MarkerStyle {
      path = path(paths::move_to(0, 0), paths::line_to(1, 0.5), paths::line_to(0, 1), paths::close_path())
      width = 16 height = 16
      fill = paint::solid_fill(c"#7c3aed") stroke = paint::no_stroke()
    }
    style = graphics::VectorStyle { stroke = paint::vector_stroke(c"#7c3aed", 3) }
  })
  ~ title.left == page.left + 64
  ~ title.top == page.top - 48
  ~ original.left == title.left
  ~ original.top == title.bottom - 48
  ~ changed.left == original.right + 40
  ~ changed.top == original.top
  ~ curved.left == changed.right + 40
  ~ curved.top == original.top
end

page reused
  let title = place!(text_api::Text { content = "# Composition and typed queries" })
  let count = place!(text_api::Text { content = "Shapes: " ++ str(selection_count(select<graphics::PathShape>(pagectx()))) })
  let row = place!((
    Diagram { label = "Original" shape = shape } ||
    Diagram { label = "Independent copy" shape = shape }
  ) with { gap = 64 })
  ~ title.left == page.left + 64
  ~ title.top == page.top - 48
  ~ count.left == title.left
  ~ count.top == title.bottom - 32
  ~ row.left == title.left
  ~ row.top == count.bottom - 48
end

page resized
  let title = place!(text_api::Text { content = "# Placement constraints resize the frame" })
  let original = place!(shape)
  let constrained = place!(shape)
  ~ title.left == page.left + 64
  ~ title.top == page.top - 48
  ~ original.left == title.left
  ~ original.top == title.bottom - 48
  ~ constrained.left == original.right + 64
  ~ constrained.top == original.top
  ~ constrained.width == 90
  ~ constrained.height == 60
end
