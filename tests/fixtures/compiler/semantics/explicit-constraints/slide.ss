import std:themes/default as *

fn beside(a: Object, b: Object, gap: Number = 24) -> Constraints
  return constraints(
    equal(anchor(b, "left"), anchor(a, "right"), gap),
    equal(anchor(b, "top"), anchor(a, "top"))
  )
end

page main
  let a = text!("Explicit")
  let b = text!("constraints")
  ~ a.left == page.left + 96
  ~ a.top == page.top - 96
  constrain!(beside(a, b))
end
