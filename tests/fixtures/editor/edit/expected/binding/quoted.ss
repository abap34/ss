page demo
let head_item = head! "Move me"
~!~ head_item.left == page.left + 120
~!~ head_item.top == page.top - 140
end
