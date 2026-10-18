import std:themes/default as *
import std:math as formulas

page algorithm
pagectx().background_fill = c"0.88,0.94,1"
let source = <<
\DontPrintSemicolon
\begin{algorithm}[H]
  \KwData{SelectableAlgorithmInput}
  \KwResult{SelectableAlgorithmResult}
  \While{condition}{update state\;}
\end{algorithm}
>>
let algorithm = latex!(source, formulas::LatexBlockStyle {}, LatexConfig { preamble = readlines("preamble.tex") })
~ algorithm.left == page.left + 240
~ algorithm.right == page.right - 240
~ algorithm.top == page.top - 100
end
