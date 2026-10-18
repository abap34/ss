import std:text/content as native

type Label {
  content: String
  prefix: String
}

type Wrapper<T> {
  content: T
  label: String
}

fn default_prefix() -> String = "Module default: "

fn/! label(content: String, prefix: String = default_prefix()) -> Label
  return Label { content = content prefix = prefix }
end

fn/! wrap<T>(content: T, label: String = "Wrapper") -> Wrapper<T>
  return Wrapper<T> { content = content label = label }
end

fn display(self: Placed<Label>) -> native::Text
  return native::Text { content = self.value.prefix ++ self.value.content }
end

fn display<T>(self: Placed<Wrapper<T>>) -> T = self.value.content
