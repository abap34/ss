import std:themes/default as *
import "./parts" as *

page title
let heading = module_label!("Project fixture", c"#334455")
text!("ss.toml + LSP smoke", default_theme().text)
text!("v1", default_theme().text)
~ heading.top == page.top - 96
end
