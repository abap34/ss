import std:components/toc as contents

page overview
  contents::toc!("Contents", contents::TocStyle {} with {
    title = default_text_style with { size = 41 }
    entries = default_text_style with { size = 23 }
  })
end
page body
  heading!("Section")
end
