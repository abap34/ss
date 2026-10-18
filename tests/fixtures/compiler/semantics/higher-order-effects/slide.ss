import std:themes/default as *
fn mark(item: Object) -> Object = set_prop(item, "link_id", "marked")
fn apply_to(item: Object, callback: Object -> Object) -> Object = callback(item)
page main
  let item = body_obj!("A")
  text!((item.link_id ?? "missing"))
  apply_to(item, mark)
end
