type Leaf = record { width: Number = 5 }
type Branch = record { leaf: Leaf? = none }

fn width(branch: Branch?) -> Number = branch?.leaf?.width ?? 0
fn label(item: Object?) -> String = item?.content ?? "missing"

page main
  let present = Branch { leaf = Leaf {} }
  let absent = Branch {}
  text!(str(width(none)) ++ ":" ++ str(width(absent)) ++ ":" ++ str(width(present)))
  text!(label(none))
end
