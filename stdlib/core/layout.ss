import std:core/classes as classes

record Cols {
  left: Number = 96
  right: Number = 96
  top: Number? = none
  gap: Number = 36
  ratio: Number = 0.5
  page_width: Number = 1280
}

record Cols2 {
  root: Object
  left: Object
  right: Object
}

fn vflow(policy: LayoutPolicy, center_offset: Number = 0) -> Void
  pagectx().layout_v = policy
  pagectx().layout_v_center_offset = center_offset
end

fn vflow_doc(policy: LayoutPolicy, center_offset: Number = 0) -> Void
  docctx().layout_v = policy
  docctx().layout_v_center_offset = center_offset
end

fn cols2_parts(left: Object, right: Object, spec: Cols = Cols {}) -> Cols2
  let root = group(left, right)
  let span = sub(sub(spec.page_width, spec.left), add(spec.right, spec.gap))
  let left_width = mul(span, spec.ratio)

  ~ left.left == page.left + spec.left
  ~ left.right == left.left + left_width
  ~ right.left == left.right + spec.gap
  ~ right.right == page.right - spec.right
  ~ right.top == left.top
  ~ root.left == left.left
  ~ root.top == left.top

  if spec.top?
    let top = spec.top ?? 0
    ~ left.top == page.top - top
  end

  return Cols2 {
    root = root
    left = left
    right = right
  }
end

fn cols2(left: Object, right: Object, spec: Cols = Cols {}) -> Object
  return cols2_parts(left, right, spec).root
end

fn surround(panel: Object, inner: Object, pad_x: Number, pad_y: Number) -> Void
  ~ panel.left == inner.left - pad_x
  ~ panel.right == inner.right + pad_x
  ~ panel.top == inner.top + pad_y
  ~ panel.bottom == inner.bottom - pad_y
end
