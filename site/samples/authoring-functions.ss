import std:themes/default

const accent: string = "0.2745,0.5098,0.7059"

fn callout(message: string, tone: string = "note") -> object
  let body = note(tone ++ ": " ++ message)
  body.text_size = 20
  border(body, 18, 12, accent, 1, 8)
  return body
end

fn setup_document() -> void
  pagenos("{page} / {total}")
  footers("function sample")
end

document
setup_document()
end

page functions_example
let title = head("Functions")
let first = callout("Default arguments keep common cases short.")
let second = callout("A second argument changes the label.", "warning")

below(first, title, 32)
below(second, first, 24)
same_l(first, title, 0)
same_l(second, first, 0)
end
