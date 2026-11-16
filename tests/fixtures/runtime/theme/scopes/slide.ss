import "./components" as ui
import std:theme as appearance

const regular: Theme = Theme {} with {
  text.size = 21
  text.headings.h2.size = 27
  text.code.size = 17
  text.headings.h6.size = 13
  page.background_fill = c"#112233"
}
const shared: Text = text("Shared")

page first
  place!(shared)
  heading!("Subsection", 2)
  place!(ui::Badge { label = "Badge" })
end

page second
  place!(shared)
  text!("Explicit", default_text_style with { size = 12 })
  place!(ui::Badge { label = "Badge" })
  code!("return 1")
  heading!("Subsection", 2)
  let large = document_theme() with {
    text.size = 35
    text.headings.h2.size = 39
    text.code.size = 22
    text.headings.h6.size = 19
    page.background_fill = c"#445566"
  }
  ui::setup!(large)
end

page third
  place!(shared)
end

document
  appearance::theme!(regular)
end
