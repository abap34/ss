import std:themes/default

fn title_line(title: object) -> string
  return "- " ++ title.content
end

page values_and_types
let title = head("Values and types")
let body = text("The page creates scalar values, graph references, selections, and constraints.")
let title_count = selection_count(objs(pagectx(), "title"))
let title_list = join(objs(pagectx(), "title"), "\n", title_line)
let summary = figure("title count = " ++ str(title_count) ++ "\n" ++ title_list)

body.text_size = 22
body.wrap = "on"
flow(body, "102", "102")

below(body, title, 32)
below(summary, body, 20)
same_l(body, title, 0)
same_l(summary, body, 0)
end
