import std:graphics/paint/types as { ChromeStyle }
import std:internal/classes
import std:layout as layout

type BoxParts {
  root: Object
  content: Object
  background: Object
}

fn box_parts(content: Object, style: ChromeStyle = ChromeStyle {}) -> BoxParts
  let background = new("", "panel", "text")
  background.chrome = style
  layout::surround(background, content, style.pad_x, style.pad_y)
  return BoxParts { root = group(background, content) content = content background = background }
end

fn/! box(content: Object, style: ChromeStyle = ChromeStyle {}) -> Object
  return box_parts(content, style).root
end
