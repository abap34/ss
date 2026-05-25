import std:themes/default

page constraint_layout
let title = head("Constraints")
let left = text("The left text block has a fixed width.")
let right = text("The right text block starts from the right edge of the left block.")
let caption = figure("Two text blocks connected by anchor constraints.")

flow(left, "102", "540")
flow(right, "560", "102")
left.text_size = 22
right.text_size = 22

below(left, title, 32)
~ right.top == left.top
~ right.left == left.right + 40
fix_w(left, 380)
fix_w(right, 380)
below(caption, left, 40)
same_l(caption, left, 0)
end
