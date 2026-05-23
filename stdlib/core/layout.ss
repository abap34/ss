import std:core/classes

fn vflow(policy: string, center_offset: number = 0) -> void
  pagectx().layout_v = policy
  pagectx().layout_v_center_offset = center_offset
end

fn vflow_doc(policy: string, center_offset: number = 0) -> void
  docctx().layout_v = policy
  docctx().layout_v_center_offset = center_offset
end

fn pin_l(node: object, amount: number) -> constraints
  return equal(anchor(node, "left"), page_anchor("left"), amount)
end

fn pin_r(node: object, amount: number) -> constraints
  return equal(anchor(node, "right"), page_anchor("right"), neg(amount))
end

fn pin_t(node: object, amount: number) -> constraints
  return equal(anchor(node, "top"), page_anchor("top"), neg(amount))
end

fn pin_b(node: object, amount: number) -> constraints
  return equal(anchor(node, "bottom"), page_anchor("bottom"), amount)
end

fn same_l(target: object, source: object, delta: number) -> constraints
  return equal(anchor(target, "left"), anchor(source, "left"), delta)
end

fn same_r(target: object, source: object, delta: number) -> constraints
  return equal(anchor(target, "right"), anchor(source, "right"), delta)
end

fn same_t(target: object, source: object, delta: number) -> constraints
  return equal(anchor(target, "top"), anchor(source, "top"), delta)
end

fn same_b(target: object, source: object, delta: number) -> constraints
  return equal(anchor(target, "bottom"), anchor(source, "bottom"), delta)
end

fn below(target: object, source: object, gap: number) -> constraints
  return equal(anchor(target, "top"), anchor(source, "bottom"), neg(gap))
end

fn fix_w(node: object, value: number) -> constraints
  return equal(anchor(node, "right"), anchor(node, "left"), value)
end

fn fix_h(node: object, value: number) -> constraints
  return equal(anchor(node, "top"), anchor(node, "bottom"), value)
end

fn inset_x(node: object, left: number, right: number) -> constraints
  return constraints(
    pin_l(node, left),
    pin_r(node, right)
  )
end

fn inset(node: object, left: number, right: number) -> object
  inset_x(node, left, right)
  return node
end

fn flow(node: object, left: string, right: string) -> object
  node.layout_x = left
  node.layout_right_inset = right
  node.wrap = "on"
  return node
end

fn tl(node: object, left: number, top: number) -> object
  pin_l(node, left)
  pin_t(node, top)
  return node
end

fn tr(node: object, right: number, top: number) -> object
  pin_r(node, right)
  pin_t(node, top)
  return node
end

fn tspan(node: object, left: number, right: number, top: number) -> object
  inset_x(node, left, right)
  pin_t(node, top)
  return node
end

fn below_l(target: object, source: object, left_delta: number, gap: number) -> object
  same_l(target, source, left_delta)
  below(target, source, gap)
  return target
end

fn below_r(target: object, source: object, right_delta: number, gap: number) -> object
  same_r(target, source, right_delta)
  below(target, source, gap)
  return target
end

fn same_tr(node: object, source: object, right: number, top_delta: number) -> object
  pin_r(node, right)
  same_t(node, source, top_delta)
  return node
end

fn cols2c(left: object, right: object, gap: number) -> constraints
  return constraints(
    equal(anchor(right, "left"), anchor(left, "right"), gap)
  )
end

fn cols2g(left: object, right: object, gap: number) -> object
  cols2c(left, right, gap)
  return group(left, right)
end

fn cols2(left: object, right: object) -> object
  return cols2g(left, right, 30)
end

fn surround(panel: object, inner: object, pad_x: number, pad_y: number) -> constraints
  return constraints(
    equal(anchor(panel, "left"), anchor(inner, "left"), neg(pad_x)),
    equal(anchor(panel, "right"), anchor(inner, "right"), pad_x),
    equal(anchor(panel, "top"), anchor(inner, "top"), pad_y),
    equal(anchor(panel, "bottom"), anchor(inner, "bottom"), neg(pad_y))
  )
end
