import std:core/classes

fn hjoin(a: Object, b: Object, gap: Number = 32) -> Object
  return compose(composition_objects(a, b), true, false, gap)
end

fn vjoin(a: Object, b: Object, gap: Number = 32) -> Object
  return compose(composition_objects(a, b), false, false, gap)
end

fn hsplit(items: Selection<Object>, gap: Number = 32) -> Object
  return compose(items, true, true, gap)
end

fn vsplit(items: Selection<Object>, gap: Number = 32) -> Object
  return compose(items, false, true, gap)
end

fn composition_objects(a: Object, b: Object) -> Selection<Object>
  return selection_union(select(a, "self_object"), select(b, "self_object"))
end

fn composition_append(items: Selection<Object>, child: Object) -> Selection<Object>
  return selection_union(items, select(child, "self_object"))
end

fn compose(items: Selection<Object>, horizontal: Bool, equal: Bool, gap: Number) -> Object
  let result = group(items)
  set_prop(result, "split_gap", gap)
  set_prop(result, "align_children_y", horizontal)
  if horizontal
    set_prop(result, "join_axis", SplitAxis.horizontal)
    if equal
      set_prop(result, "split_axis", SplitAxis.horizontal)
    end
  else
    set_prop(result, "join_axis", SplitAxis.vertical)
    if equal
      set_prop(result, "split_axis", SplitAxis.vertical)
    end
  end
  return result
end

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

fn hflow(policy: LayoutPolicy, center_offset: Number = 0) -> Void
  pagectx().layout_h = policy
  pagectx().layout_h_center_offset = center_offset
end

fn hflow_doc(policy: LayoutPolicy, center_offset: Number = 0) -> Void
  docctx().layout_h = policy
  docctx().layout_h_center_offset = center_offset
end

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
