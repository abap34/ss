import std:core/classes as *

fn vflow(policy: LayoutPolicy, center_offset: Number = 0) -> Void
  pagectx().layout_v = policy
  pagectx().layout_v_center_offset = center_offset
end

fn vflow_doc(policy: LayoutPolicy, center_offset: Number = 0) -> Void
  docctx().layout_v = policy
  docctx().layout_v_center_offset = center_offset
end

fn pin_l(node: Object, amount: Number) -> Constraints
  return equal(anchor(node, "left"), page_anchor("left"), amount)
end

fn pin_r(node: Object, amount: Number) -> Constraints
  return equal(anchor(node, "right"), page_anchor("right"), neg(amount))
end

fn pin_t(node: Object, amount: Number) -> Constraints
  return equal(anchor(node, "top"), page_anchor("top"), neg(amount))
end

fn pin_b(node: Object, amount: Number) -> Constraints
  return equal(anchor(node, "bottom"), page_anchor("bottom"), amount)
end

fn same_l(target: Object, source: Object, delta: Number) -> Constraints
  return equal(anchor(target, "left"), anchor(source, "left"), delta)
end

fn same_r(target: Object, source: Object, delta: Number) -> Constraints
  return equal(anchor(target, "right"), anchor(source, "right"), delta)
end

fn same_t(target: Object, source: Object, delta: Number) -> Constraints
  return equal(anchor(target, "top"), anchor(source, "top"), delta)
end

fn same_b(target: Object, source: Object, delta: Number) -> Constraints
  return equal(anchor(target, "bottom"), anchor(source, "bottom"), delta)
end

fn below(target: Object, source: Object, gap: Number) -> Constraints
  return equal(anchor(target, "top"), anchor(source, "bottom"), neg(gap))
end

fn fix_w(node: Object, value: Number) -> Constraints
  return equal(anchor(node, "right"), anchor(node, "left"), value)
end

fn fix_h(node: Object, value: Number) -> Constraints
  return equal(anchor(node, "top"), anchor(node, "bottom"), value)
end

fn inset_x(node: Object, left: Number, right: Number) -> Constraints
  return constraints(
    pin_l(node, left),
    pin_r(node, right)
  )
end

fn inset(node: Object, left: Number, right: Number) -> Object
  inset_x(node, left, right)
  return node
end

fn flow(node: Object, left: Number, right: Number) -> Object
  node.layout_x = left
  node.layout_right_inset = right
  node.wrap = WrapMode.on
  return node
end

fn tl(node: Object, left: Number, top: Number) -> Object
  pin_l(node, left)
  pin_t(node, top)
  return node
end

fn tr(node: Object, right: Number, top: Number) -> Object
  pin_r(node, right)
  pin_t(node, top)
  return node
end

fn tspan(node: Object, left: Number, right: Number, top: Number) -> Object
  inset_x(node, left, right)
  pin_t(node, top)
  return node
end

fn below_l(target: Object, source: Object, left_delta: Number, gap: Number) -> Object
  same_l(target, source, left_delta)
  below(target, source, gap)
  return target
end

fn below_r(target: Object, source: Object, right_delta: Number, gap: Number) -> Object
  same_r(target, source, right_delta)
  below(target, source, gap)
  return target
end

fn same_tr(node: Object, source: Object, right: Number, top_delta: Number) -> Object
  pin_r(node, right)
  same_t(node, source, top_delta)
  return node
end

fn cols2(left: Object, right: Object, gap: Number = 30) -> Constraints
  return constraints(
    equal(anchor(right, "left"), anchor(left, "right"), gap)
  )
end



fn surround(panel: Object, inner: Object, pad_x: Number, pad_y: Number) -> Constraints
  return constraints(
    equal(anchor(panel, "left"), anchor(inner, "left"), neg(pad_x)),
    equal(anchor(panel, "right"), anchor(inner, "right"), pad_x),
    equal(anchor(panel, "top"), anchor(inner, "top"), pad_y),
    equal(anchor(panel, "bottom"), anchor(inner, "bottom"), neg(pad_y))
  )
end
