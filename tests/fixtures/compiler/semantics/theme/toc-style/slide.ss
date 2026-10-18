import std:components/toc as contents

page overview
  contents::toc!("Contents", contents::TocStyle {} with {
    title.text.size = 41
    body.text.size = 23
  })
end
page body
  heading!("Section")
end
