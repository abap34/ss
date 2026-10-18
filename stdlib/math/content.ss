import std:math/style as { LatexBlockStyle }
import std:math/types as { LatexConfig }

type Latex {
  source: String
  style: LatexBlockStyle = LatexBlockStyle {}
  config: LatexConfig = LatexConfig {}
}

type Math {
  source: String
  style: LatexBlockStyle = LatexBlockStyle {}
  config: LatexConfig = LatexConfig {}
}

fn display(self: Placed<Math>) -> Latex
  return Latex {
    ;; A newline protects the closing delimiter from trailing TeX comments.
    source = "$\displaystyle " ++ self.value.source ++ "
$"
    style = self.value.style
    config = self.value.config
  }
end
