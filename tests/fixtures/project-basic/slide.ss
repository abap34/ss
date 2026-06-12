import std:themes/default as *
import "./parts" as *

page title
let heading = module_label!("Project fixture")
cover!(
  "Project fixture",
  "ss.toml + LSP smoke",
  "v1"
)
heading.text_color = c"#334455"
~ heading.top == page.top - 96
end
