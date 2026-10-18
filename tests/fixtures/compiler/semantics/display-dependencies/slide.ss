type Label { format: () -> String }
fn formatter(prefix: String) -> () -> String
  return () |-> prefix ++ (docctx().footer_text ?? "missing")
end
fn display(self: Placed<Label>) -> Text = text(self.value.format())
page main
  place!(Label { format = formatter("A") })
end
document
  docctx().footer_text = "!"
end
