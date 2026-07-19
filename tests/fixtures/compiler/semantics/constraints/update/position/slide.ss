import std:themes/default as *

fn component!() -> Object
  let item = text!("move")
  ~ item.center_x == page.center_x
  ~ item.top == page.top - 60
  ~ item.width == 240
  return item
end

page demo
  let item = component!()
  ~!~item.left == page.left + 80
  ~!~item.top == page.top - 120
end
