import std:themes/default as *

page icon_collection
let star = icon!("fa-solid:star")
let circle = icon!("fa-regular:circle", AssetBlockStyle {} with { asset.tint = c"#16a34a" })
let github = icon!("fa-brands:github", AssetBlockStyle {} with { asset.tint = c"#111827" })
~ star.left == page.left + 120
~ star.top == page.top - 120
~ circle.left == star.right + 48
~ circle.top == star.top
~ github.left == circle.right + 48
~ github.top == star.top
end
