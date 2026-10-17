import std:layout/types
enum MathFit { none shrink }

enum LatexEngine { pdflatex lualatex }

type LatexStyle {
  scale: Number = 1
  min_height: Number = 30
  align: Align = Align.center
}
