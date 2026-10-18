import std:math as math
import std:text as text_api

type Formula { body: math::Latex }
fn display(self: Placed<Formula>) -> math::Latex = self.value.body

const body: math::Latex = math::latex(<<
\textbf{LaTeX body}\quad $\Example{x}=x^2$
>>, math::LatexBlockStyle {}, math::LatexConfig {
  preamble = <<
\newcommand{\Example}[1]{f(#1)}
>>
})

page normal
  let title = place!(text_api::Text { content = "# Typed LaTeX content" })
  let formula: Placed<math::Latex> = math::latex!(body.source, body.style, body.config)
  ~ title.left == page.left + 64
  ~ title.top == page.top - 48
  ~ formula.left == title.left
  ~ formula.top == title.bottom - 48
end

page enlarged
  let formula = place!(body with { style.latex.scale = 2 })
  ~ formula.left == page.left + 64
  ~ formula.top == page.top - 160
end

page wrapped
  let formula = place!(Formula { body = body })
  ~ formula.left == page.left + 64
  ~ formula.top == page.top - 160
end
