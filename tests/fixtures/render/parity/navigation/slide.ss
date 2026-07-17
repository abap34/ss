import std:themes/default as *

page first
page_bg(c"0.94,0.97,1")
let title = h1!("First page")
~ title.left == page.left + 96
~ title.top == page.top - 72
end

page second
page_bg(c"0.96,1,0.96")
let title = h1!("Second page")
~ title.left == page.left + 96
~ title.top == page.top - 72
end

page third
page_bg(c"1,0.96,0.94")
let title = h1!("Third page")
~ title.left == page.left + 96
~ title.top == page.top - 72
end
