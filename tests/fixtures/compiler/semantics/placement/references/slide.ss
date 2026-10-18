type Reference { target: Placed<Text> }
type Linked {
  referent: Placed<Text>?
  wrapped: Reference?
}
fn display(self: Placed<Linked>) -> Text = text("Holder")

page main
  let target = text!("Target")
  place!(Linked { referent = target wrapped = Reference { target = target } })
end
