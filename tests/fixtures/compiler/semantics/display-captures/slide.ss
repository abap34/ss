type Label { content: String format: String -> String }
fn make(content: String, suffix: String) -> Label
  return Label { content = content format = (value: String) |-> value ++ suffix }
end
fn display(self: Placed<Label>) -> Text = text(self.value.format(self.value.content))
page main
  place!(make("A", "!"))
  place!(make("B", "?"))
end
