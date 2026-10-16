import std:themes/default as *

page fallback_baselines
let heading = h1!("LaTeX baselines")
~ heading.left == page.left + 72
~ heading.top == page.top - 56

let deep = text!("A $\ParityToken_{gjpqy}^{B}$ A", current_theme() with {
  body.text.size = 64
  body.text.line_height = 84
})
~ deep.left == heading.left
~ deep.top == heading.bottom - 48

let tall = text!("A $\frac{\ParityToken^{B}}{gjpqy}$ A", current_theme() with {
  body.text.size = 64
  body.text.line_height = 96
})
~ tall.left == heading.left
~ tall.top == deep.bottom - 56
end

document
  latex_preamble_file("preamble.tex")
end
