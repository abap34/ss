import std:themes/default as *

page latex_math
let heading = heading!("LaTeX mathematics", 1, default_theme().h1)
let expression = latex!("$x_1^2 + \frac{\alpha}{\sqrt{y}}$")
~ heading.left == page.left + 96
~ heading.top == page.top - 72
~ expression.left == page.left + 160
~ expression.top == heading.bottom - 72
end
