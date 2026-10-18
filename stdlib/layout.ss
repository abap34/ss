import std:layout/types as { Align, LayoutPolicy, SplitAxis, WrapMode, FitPolicy, LayoutStyle }
import std:internal/classes

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

fn place!<T>(value: T) -> Placed<T>
  return place_on!(pagectx(), value)
end
