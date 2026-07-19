import std:themes/default as *

fn component!() -> Object
  let item = text!("caller")
  ~!~item.left == page.left + 40
  ~ item.top == page.top - 60
  return item
end

page demo
  let item = component!()
  ~!~item.right == page.right - 80
end
