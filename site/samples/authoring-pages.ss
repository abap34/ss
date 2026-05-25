import std:themes/default

document
pagenos("{page} / {total}")
footers("page sample")
need_titles()
end

page pages_cover
cover("Pages", "Document block and page block", "ss")
end

page pages_body
let title = head("Page body")
let body = text("The second page is written after the cover in the source file.")
below(body, title, 32)
end

page pages_summary
let title = head("Summary")
let total = page_count(docctx())
let body = text("This document has " ++ str(total) ++ " pages.")
below(body, title, 32)
end
