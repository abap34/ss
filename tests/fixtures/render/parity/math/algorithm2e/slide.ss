import std:themes/default as *

page algorithm
page_bg(c"0.88,0.94,1")
let algorithm = tex! <<
\DontPrintSemicolon
\begin{algorithm}[H]
  \KwData{SelectableAlgorithmInput}
  \KwResult{SelectableAlgorithmResult}
  \While{condition}{update state\;}
\end{algorithm}
>>
algorithm.math.raw_tex_width_ratio = 1
~ algorithm.left == page.left + 240
~ algorithm.right == page.right - 240
~ algorithm.top == page.top - 100
end

document
  tex_preamble_file("preamble.tex")
end
