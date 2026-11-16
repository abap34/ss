import std:themes/default as base

fn decorate!(p: Page) -> Void
  let theme = base::default_theme()
  place_on!(p, pageno(theme.text with { size = 17 }))
  place_on!(p, text("Footer", theme.text with { size = 18 }))
  place_on!(p, text("Draft", theme.text with { size = 19 }))
end

document
  foreach(pages(docctx()), (p: Page) |-> decorate!(p))
end
page ok
end
