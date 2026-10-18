import std:themes/default as *

type Link = object {
  base = Text
  roles = ["link"]
  peer: Object?
}
fn formatter(fallback: Object) -> Object -> String
  return (item: Object) |-> repr(item.peer ?? fallback) ++ "!"
end
page main
  let leaf = text("leaf")
  let a = txt_obj("A", "link")
  a.peer = leaf
  set_repr(a, formatter(leaf))
  let b = txt_obj("B", "link")
  b.peer = a
  set_repr(b, formatter(leaf))
  place_on!(pagectx(), leaf)
  place_on!(pagectx(), a)
  place_on!(pagectx(), b)
end
