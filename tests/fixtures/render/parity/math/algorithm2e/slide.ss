import std:themes/default as *

page algorithm
page_bg(c"0.88,0.94,1")
let algorithm = latex! <<
\DontPrintSemicolon
\begin{algorithm}[H]
  \KwData{SelectableAlgorithmInput}
  \KwResult{SelectableAlgorithmResult}
  \While{condition}{update state\;}
\end{algorithm}
>>
~ algorithm.left == page.left + 240
~ algorithm.right == page.right - 240
~ algorithm.top == page.top - 100
end

document
  latex_preamble_file("preamble.tex")
end
