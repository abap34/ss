import std:themes/default as *

fn component!() -> Object
  let item = text!("fallback")
  ~ item.center_x == page.center_x
  ~ item.top == page.top - 60
  return item
end

page demo
  let item = component!()
  ~!~item.left
  ~!~item.top
end
