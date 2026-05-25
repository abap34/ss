import std:themes/default

document
pagenos("{page} / {total}")
end

page object_roles
let title = head("Objects and roles")
let body = text <<
The page contains text, math, and a figure caption.
Each component returns an object that can be positioned.
>>
let eq = tex("\\sum_{i=1}^{n} i", 1.0)
let cap = figure("Equation 1. Sum notation")

below(body, title, 32)
below(eq, body, 28)
below(cap, eq, 16)
same_l(body, title, 0)
same_l(eq, body, 0)
same_l(cap, body, 0)
end
