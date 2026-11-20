import std:themes/default as *

fn beside<A, B>(a: Placed<A>, b: Placed<B>, gap: Number = 24) -> Constraints
  return constraints(
    (b.left == a.right + gap),
    (b.top == a.top)
  )
end

page main
  let a = text!("Explicit", default_text_style with { layout.wrap = WrapMode.off })
  let b = text!("constraints", default_text_style with { layout.wrap = WrapMode.off })
  ~ a.left == page.left + 96
  ~ a.top == page.top - 96
  ~ beside(a, b)
end
