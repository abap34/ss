import std:layout/types
enum MathFit { none shrink }

enum LatexEngine { pdflatex lualatex }

type LatexConfig {
  engine: LatexEngine = LatexEngine.pdflatex
  preamble: String = ""
}
