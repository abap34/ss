page demo
let item = text!("Move me")
~ item.left == page.left + horizontal_gap
~ item.top == page.top - 96
~!~ item.right == page.right - 40; // previous editor position
end
