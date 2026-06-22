import std:themes/default as *
import "./parts" as *

page title
let heading = module_label!("Project fixture", c"#334455")
cover!(
  "Project fixture",
  "ss.toml + LSP smoke",
  "v1"
)
~ heading.top == page.top - 96
end
