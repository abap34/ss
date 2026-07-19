import std:themes/default as *

const left_offset: Number = 72

fn movable!(guide: Object) -> Object
  let result = text!("Move me")
  ~ result.left == guide.right + left_offset
  ~ result.top == guide.bottom - 24
  return result
end

page demo
let guide = text!("Guide")
let item = movable!(guide)
~ guide.left == page.left + 100
~ guide.top == page.top - 100
end
