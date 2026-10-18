type Reference { target: Object }
type Linked = object {
  roles = ["linked"]
  referent: Object?
  wrapped: Reference?
}

page main
  let target = body_obj!("Target")
  let holder = txt_obj!("Holder", "linked")
  holder.referent = target
  holder.wrapped = Reference { target = target }
end
