import std:themes/default as *
fn label(item: Object) -> String = content(item) ++ (docctx().footer_text ?? "")
page main
  let item = set_repr(txt_obj!("A", "claim"), label)
  note!("repr=" ++ repr(item))
end
document
  docctx().footer_text = "!"
end
