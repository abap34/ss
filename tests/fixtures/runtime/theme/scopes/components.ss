type Badge { label: String }

fn display(self: Placed<Badge>) -> Text
  return text(self.value.label, theme_for(self.page).label)
end

fn setup!(value: Theme) -> Void
  text!("Same unit")
  theme!(value)
end
