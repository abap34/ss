import std:themes/default

document
pagenos("{page} / {total}")
footers("generated from document context")
need_titles()
end

page cover_page
cover("Document generation", "Page numbers, footers, and table of contents", "ss")
end

page toc_page
let title = head("Table of contents")
let list = toc_obj()
below(list, title, 32)
end

page first_topic
let title = head("First topic")
let body = text("The document block reads the page list and adds generated objects.")
below(body, title, 32)
end

page second_topic
let title = head("Second topic")
let body = text("The table of contents reads title objects and page indexes.")
below(body, title, 32)
end
