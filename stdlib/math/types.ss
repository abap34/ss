import std:layout/types
type MathFit = none | shrink

type LatexEngine = pdflatex | lualatex

type LatexStyle = record {
  scale: Number = 1
  min_height: Number = 30
  align: Align = Align.center
}
