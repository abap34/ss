import std:themes/default as *
import "./parts" as *

page title
let heading = module_label!("Project fixture", c"#334455")
text!("ss.toml + LSP smoke", default_theme().h2)
text!("v1", default_theme().byline)
~ heading.top == page.top - 96
end
