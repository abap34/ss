page demo
let item = text!("Move me")
~ item.left == page.left + horizontal_gap
~ item.top == page.top - 96
~!~ item.left == page.left + 120; // previous editor position
~!~ item.top == page.top - 140
end
