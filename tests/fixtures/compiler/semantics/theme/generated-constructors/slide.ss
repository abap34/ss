import std:themes/default as base

fn decorate!(p: Page) -> Void
  let theme = base::default_theme()
  place_on!(p, pageno(theme.page_number with { text.size = 17 }))
  place_on!(p, text("Footer", theme.note with { text.size = 18 }))
  place_on!(p, text("Draft", theme.note with { text.size = 19 }))
end

document
  foreach(pages(docctx()), (p: Page) |-> decorate!(p))
end
page ok
end
