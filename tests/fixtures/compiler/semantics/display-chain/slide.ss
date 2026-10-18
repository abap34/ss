type Outer { format: () -> String }
type Inner { format: () -> String }
fn formatter(value: String) -> () -> String = () |-> value ++ "!"
fn display(self: Placed<Outer>) -> Inner
  let format = self.value.format
  return Inner { format = () |-> format() ++ "!" }
end
fn display(self: Placed<Inner>) -> Text = text(self.value.format())
page main
  place!(Outer { format = formatter("leaf") })
end
