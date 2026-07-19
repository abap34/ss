import std:themes/default as *

page demo
  let item = text!("duplicate")
  ~!~item.left == page.left + 40
  ~!~item.right == page.right - 40
  ~ item.top == page.top - 80
end
