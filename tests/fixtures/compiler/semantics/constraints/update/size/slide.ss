import std:themes/default as *

fn component!() -> Object
  let item = text!("resize")
  ~ item.center_x == page.center_x
  ~ item.top == page.top - 60
  ~ item.width == 240
  return item
end

page demo
  let item = component!()
  ~!~item.width == 320
end
