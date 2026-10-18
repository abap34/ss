import std:themes/default as *

const config: LatexConfig = LatexConfig { preamble = readlines("preamble.tex") }

page fallback_baselines
let heading = h1!("LaTeX baselines")
~ heading.left == page.left + 72
~ heading.top == page.top - 56

let deep = text!("A $\ParityToken_{gjpqy}^{B}$ A", default_theme().body with {
  text.size = 64
  text.line_height = 84
}, config)
~ deep.left == heading.left
~ deep.top == heading.bottom - 48

let tall = text!("A $\frac{\ParityToken^{B}}{gjpqy}$ A", default_theme().body with {
  text.size = 64
  text.line_height = 96
}, config)
~ tall.left == heading.left
~ tall.top == deep.bottom - 56
end
