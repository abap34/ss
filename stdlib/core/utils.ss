import std:core/classes

fn math_align(obj: Object, align_name: Align) -> Object
  obj.math_align = align_name
  return obj
end

fn left_math(obj: Object) -> Object
  return math_align(obj, Align.left)
end

fn center_math(obj: Object) -> Object
  return math_align(obj, Align.center)
end

fn right_math(obj: Object) -> Object
  return math_align(obj, Align.right)
end

fn math_align_all(align_name: Align) -> Void
  docctx().math_align = align_name
end

fn left_math_all() -> Void
  math_align_all(Align.left)
end

fn center_math_all() -> Void
  math_align_all(Align.center)
end

fn right_math_all() -> Void
  math_align_all(Align.right)
end

fn math_align_objects(items: Selection<Object>, align_name: Align) -> Selection<Object>
  items.math_align = align_name
  return items
end
