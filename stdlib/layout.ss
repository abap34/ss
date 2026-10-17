import std:layout/types as { Align, LayoutPolicy, SplitAxis, WrapMode, FitPolicy, LayoutStyle }
import std:internal/classes

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
  result.split_gap = gap
  result.align_children_y = horizontal
  if horizontal
    result.join_axis = SplitAxis.horizontal
    if equal
      result.split_axis = SplitAxis.horizontal
    end
  else
    result.join_axis = SplitAxis.vertical
    if equal
      result.split_axis = SplitAxis.vertical
    end
  end
  return result
end

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

fn surround(panel: Object, inner: Object, pad_x: Number, pad_y: Number) -> Void
  ~ panel.left == inner.left - pad_x
  ~ panel.right == inner.right + pad_x
  ~ panel.top == inner.top + pad_y
  ~ panel.bottom == inner.bottom - pad_y
end

fn place!(obj: Object) -> Object
  return place_on!(pagectx(), obj)
end
