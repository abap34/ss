fn left_inset(node: object, amount: number) -> constraints
  return equal(anchor(node, "left"), page_anchor("left"), amount)
end

fn right_inset(node: object, amount: number) -> constraints
  return equal(anchor(node, "right"), page_anchor("right"), neg(amount))
end

fn top_inset(node: object, amount: number) -> constraints
  return equal(anchor(node, "top"), page_anchor("top"), neg(amount))
end

fn bottom_inset(node: object, amount: number) -> constraints
  return equal(anchor(node, "bottom"), page_anchor("bottom"), amount)
end

fn same_left(target: object, source: object, delta: number) -> constraints
  return equal(anchor(target, "left"), anchor(source, "left"), delta)
end

fn same_right(target: object, source: object, delta: number) -> constraints
  return equal(anchor(target, "right"), anchor(source, "right"), delta)
end

fn same_top(target: object, source: object, delta: number) -> constraints
  return equal(anchor(target, "top"), anchor(source, "top"), delta)
end

fn same_bottom(target: object, source: object, delta: number) -> constraints
  return equal(anchor(target, "bottom"), anchor(source, "bottom"), delta)
end

fn below(target: object, source: object, gap: number) -> constraints
  return equal(anchor(target, "top"), anchor(source, "bottom"), neg(gap))
end

fn fixed_width(node: object, width: number) -> constraints
  return equal(anchor(node, "right"), anchor(node, "left"), width)
end

fn fixed_height(node: object, height: number) -> constraints
  return equal(anchor(node, "top"), anchor(node, "bottom"), height)
end

fn inset_x(node: object, left: number, right: number) -> constraints
  return constraints(
    left_inset(node, left),
    right_inset(node, right)
  )
end

fn inset_node(node: object, left: number, right: number) -> object
  inset_x(node, left, right)
  return node
end

fn flow_inset(node: object, left: string, right: string) -> object
  set_prop(node, "layout_x", left)
  set_prop(node, "layout_right_inset", right)
  return node
end

fn place_top_left(node: object, left: number, top: number) -> object
  left_inset(node, left)
  top_inset(node, top)
  return node
end

fn place_top_right(node: object, right: number, top: number) -> object
  right_inset(node, right)
  top_inset(node, top)
  return node
end

fn place_top_span(node: object, left: number, right: number, top: number) -> object
  inset_x(node, left, right)
  top_inset(node, top)
  return node
end

fn place_below_left(target: object, source: object, left_delta: number, gap: number) -> object
  same_left(target, source, left_delta)
  below(target, source, gap)
  return target
end

fn place_below_right(target: object, source: object, right_delta: number, gap: number) -> object
  same_right(target, source, right_delta)
  below(target, source, gap)
  return target
end

fn place_same_top_right(node: object, source: object, right: number, top_delta: number) -> object
  right_inset(node, right)
  same_top(node, source, top_delta)
  return node
end

fn two_columns_constraints(left: object, right: object, gap: number, right_inset_value: number) -> constraints
  return constraints(
    equal(anchor(right, "left"), anchor(left, "right"), gap),
    left_inset(left, 96),
    ;; right_inset(right, right_inset_value)
  )
end

fn two_columns_gap(left: object, right: object, gap: number) -> object
  two_columns_constraints(left, right, gap, 96)
  return group(left, right)
end

fn two_columns(left: object, right: object) -> object
  return two_columns_gap(left, right, 30)
end

fn surround(panel: object, inner: object, pad_x: number, pad_y: number) -> constraints
  return constraints(
    equal(anchor(panel, "left"), anchor(inner, "left"), neg(pad_x)),
    equal(anchor(panel, "right"), anchor(inner, "right"), pad_x),
    equal(anchor(panel, "top"), anchor(inner, "top"), pad_y),
    equal(anchor(panel, "bottom"), anchor(inner, "bottom"), neg(pad_y))
  )
end
