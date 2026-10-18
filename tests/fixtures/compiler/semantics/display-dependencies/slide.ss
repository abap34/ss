type Label { format: () -> String }
fn formatter(prefix: String) -> () -> String
  return () |-> prefix ++ str(docctx().layout_h_center_offset)
end
fn display(self: Placed<Label>) -> Text = text(self.value.format())
page main
  place!(Label { format = formatter("A") })
end
document
  docctx().layout_h_center_offset = 42
end
