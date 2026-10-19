import std:layout/types as { Align, LayoutPolicy, WrapMode, FitPolicy, LayoutStyle, GroupLayout }
import std:document/settings as settings

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

fn place!<T>(value: T) -> Placed<T>
  return place_on!(pagectx(), value)
end
