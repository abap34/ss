import std:themes/default as *

page first
pagectx().background_fill = c"0.94,0.97,1"
let title = heading!("First page", 1, default_theme().h1)
~ title.left == page.left + 96
~ title.top == page.top - 72
end

page second
pagectx().background_fill = c"0.96,1,0.96"
let title = heading!("Second page", 1, default_theme().h1)
~ title.left == page.left + 96
~ title.top == page.top - 72
end

page third
pagectx().background_fill = c"1,0.96,0.94"
let title = heading!("Third page", 1, default_theme().h1)
~ title.left == page.left + 96
~ title.top == page.top - 72
end
