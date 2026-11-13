import "./components" as ui
import std:theme as appearance

const regular: Theme = Theme {} with {
  body.text.size = 21
  h2.text.size = 27
  code.text.size = 17
  label.text.size = 13
  background_fill = c"#112233"
}
const shared: Text = text("Shared")

page first
  place!(shared)
  heading!("Subsection", 2)
  place!(ui::Badge { label = "Badge" })
end

page second
  place!(shared)
  text!("Explicit", default_text_style with { text.size = 12 })
  place!(ui::Badge { label = "Badge" })
  code!("return 1")
  heading!("Subsection", 2)
  let large = document_theme() with {
    body.text.size = 35
    h2.text.size = 39
    code.text.size = 22
    label.text.size = 19
    background_fill = c"#445566"
  }
  ui::setup!(large)
end

page third
  place!(shared)
end

document
  appearance::theme!(regular)
end
