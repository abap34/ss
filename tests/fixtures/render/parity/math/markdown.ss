import std:themes/default as *

page markdown_math
let heading = h1!("Mathematics in text")
let body = text! <<
Inline mathematics keeps $x_1^2 + \alpha$ on the text baseline．

$$
\frac{a+b}{\sqrt{c}}
$$

The paragraph continues after the displayed expression．
>>
~ heading.left == page.left + 96
~ heading.top == page.top - 72
~ body.left == page.left + 96
~ body.top == heading.bottom - 48
~ body.right == page.right - 96
end
