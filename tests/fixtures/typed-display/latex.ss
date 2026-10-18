import std:math as math
import std:text as text_api

type Formula { body: math::Latex }
fn display(self: Placed<Formula>) -> math::Latex = self.value.body

const body: math::Latex = math::Latex {
  source = <<
\textbf{LaTeX body}\quad $\Example{x}=x^2$
>>
  config = math::LatexConfig {
    preamble = <<
\newcommand{\Example}[1]{f(#1)}
>>
  }
}

page normal
  let title = place!(text_api::Text { content = "# Typed LaTeX content" })
  let formula = place!(body)
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
