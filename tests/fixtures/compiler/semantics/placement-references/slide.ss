import std:document as doc

type Algorithm {
  title: String
  other: Ref<Placed<Algorithm>>
}

fn number(target: Placed<Algorithm>) -> String
  return str(doc::number_of(target, select<Algorithm>(target.document)) ?? 0)
end

fn display(self: Placed<Algorithm>) -> Text
  let other = *self.value.other
  return text(self.value.title ++ " refers to " ++ other.value.title ++ " (" ++ number(other) ++ ")")
end

fn algorithm!(title: String, other: Ref<Placed<Algorithm>>) -> Placed<Algorithm>
  return place!(Algorithm { title = title other = other })
end

page methods
  let split = algorithm!("Split", &merge)
  let merge = algorithm!("Merge", &split)
end

page summary
  let target = &methods::merge
  let describe = () |-> (*target).value.title
  text!("Earlier: " ++ describe())
end
