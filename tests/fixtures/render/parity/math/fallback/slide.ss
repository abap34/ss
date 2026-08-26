import std:themes/default as *

page fallback_baselines
let heading = h1!("LaTeX baselines")
~ heading.left == page.left + 72
~ heading.top == page.top - 56

let deep = text!("A $\ParityToken_{gjpqy}^{B}$ A")
deep.text.size = 64
deep.text.line_height = 84
~ deep.left == heading.left
~ deep.top == heading.bottom - 48

let tall = text!("A $\frac{\ParityToken^{B}}{gjpqy}$ A")
tall.text.size = 64
tall.text.line_height = 96
~ tall.left == heading.left
~ tall.top == deep.bottom - 56
end

document
  latex_preamble_file("preamble.tex")
end
