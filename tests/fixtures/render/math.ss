import std:themes/default as *

page latex_math
let heading = h1!("LaTeX mathematics")
let expression = latex!("$x_1^2 + \frac{\alpha}{\sqrt{y}}$")
~ heading.left == page.left + 96
~ heading.top == page.top - 72
~ expression.left == page.left + 160
~ expression.top == heading.bottom - 72
end
