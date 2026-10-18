import std:math as formulas
import std:text as text_api

const config: formulas::LatexConfig = formulas::LatexConfig {
  preamble = <<
\newcommand{\Example}[1]{f(#1)}
>>
}
const shared: Math = formulas::math("\Example{x} = x^2", formulas::LatexBlockStyle {}, config)

page normal
  let title = place!(text_api::Text { content = "# Mathematical expressions" })
  let first = place!(shared)
  let fraction = math!("\frac{a+b}{c} % trailing comment")
  ~ title.left == page.left + 64
  ~ title.top == page.top - 48
  ~ first.left == title.left
  ~ first.top == title.bottom - 48
  ~ fraction.left == first.right + 64
  ~ fraction.top == first.top
end

page enlarged
  let title = place!(text_api::Text { content = "# Independent scaling" })
  let formula = place!(shared with { style.latex.scale = 2 })
  ~ title.left == page.left + 64
  ~ title.top == page.top - 48
  ~ formula.left == title.left
  ~ formula.top == title.bottom - 48
end

page combined
  let title = place!(text_api::Text { content = "# Reusable formula composition" })
  let summary = place!(text_api::Text { content = "Formulas: " ++ str(selection_count(select<Math>(pagectx()))) })
  let row = place!((shared || shared) with { gap = 64 })
  ~ title.left == page.left + 64
  ~ title.top == page.top - 48
  ~ summary.left == title.left
  ~ summary.top == title.bottom - 32
  ~ row.left == title.left
  ~ row.top == summary.bottom - 48
end
