import std:themes/default as *

fn beside(a: Object, b: Object, gap: Number = 24) -> Constraints
  return constraints(
    (b.left == a.right + gap),
    (b.top == a.top)
  )
end

page main
  let a = body_obj!("Explicit")
  let b = body_obj!("constraints")
  ~ a.left == page.left + 96
  ~ a.top == page.top - 96
  ~ beside(a, b)
end
