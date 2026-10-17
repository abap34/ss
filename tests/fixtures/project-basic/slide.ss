import std:themes/default as *
import "./parts" as *

page title
let heading = module_label!("Project fixture", c"#334455")
subtitle!("ss.toml + LSP smoke")
byline!("v1")
~ heading.top == page.top - 96
end
