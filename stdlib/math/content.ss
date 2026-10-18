import std:math/style as { LatexBlockStyle }
import std:math/types as { LatexConfig }

type Latex {
  source: String
  style: LatexBlockStyle = LatexBlockStyle {}
  config: LatexConfig = LatexConfig {}
}
