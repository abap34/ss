import std:themes/default as *

const horizontal_gap: Number = 20
const vertical_gap: Number = 30

page demo
let guide = text!("Guide")
let item = text!("Item")
~ guide.left == page.left + 100
~ guide.top == page.top - 100
~ item.center_x == guide.right + horizontal_gap
~ item.bottom == guide.top - vertical_gap
end
