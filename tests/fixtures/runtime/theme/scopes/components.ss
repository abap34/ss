import std:document/content as { heading_text }

type Badge { label: String }

fn display(self: Placed<Badge>) -> Text
  return heading_text(self.value.label, 6)
end

fn setup!(value: Theme) -> Void
  text!("Same unit")
  theme!(value)
end
