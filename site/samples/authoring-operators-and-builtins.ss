import std:themes/default

page operators_example
let title = head("Operators")
let left = 72
let gutter = 32
let column_width = (1024 - left * 2 - gutter) / 2
let total_width = add(mul(column_width, 2), gutter)
let label_text = "column width = " ++ str(column_width) ++ "\n" ++ "total width = " ++ str(total_width)
let label = text(label_text)
let note_text = figure(replace("layout uses {n} columns", "{n}", str(2)))

label.text_size = 22
label.text_line_height = 30
flow(label, "102", "102")

below(label, title, 32)
below(note_text, label, 20)
same_l(label, title, 0)
same_l(note_text, label, 0)
end
