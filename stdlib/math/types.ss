import std:layout/types
enum MathFit { none shrink }

enum LatexEngine { pdflatex lualatex }

type LatexStyle = record {
  scale: Number = 1
  min_height: Number = 30
  align: Align = Align.center
}
