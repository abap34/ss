import std:themes/default

page styled_objects
let title = head("Properties")
let body = text("Properties change text size, color, wrapping, borders, and spacing.")
body.text_size = 24
body.text_line_height = 34
body.text_color = "0.12,0.14,0.18"
flow(body, "102", "102")

let sample = code("""
fn main() {
  return 0
}
""", "zig")
sample.text_size = 15
sample.text_line_height = 20
border(sample, 18, 12, "0.30,0.45,0.72", 1, 8)

below(body, title, 32)
below(sample, body, 28)
same_l(body, title, 0)
same_l(sample, body, 0)
end
