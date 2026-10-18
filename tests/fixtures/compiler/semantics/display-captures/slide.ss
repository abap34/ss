import std:themes/default as *

fn make() -> Object = text("A")
page main
  let a = make()
  let b = make()
  set_repr(a, (self: Object) |-> repr(b) ++ "!")
  set_repr(b, (self: Object) |-> content(self))
  place_on!(pagectx(), a)
  place_on!(pagectx(), b)
end
