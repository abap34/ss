import std:math/types as { MathFit, LatexEngine, LatexStyle, LatexConfig }
import std:math/content as { Latex, Math }
import std:math/style as { LatexBlockStyle }

fn/! math(source: String, style: LatexBlockStyle = LatexBlockStyle {}, config: LatexConfig = LatexConfig {}) -> Math
  return Math { source = source style = style config = config }
end

fn/! latex(source: String, style: LatexBlockStyle = LatexBlockStyle {}, config: LatexConfig = LatexConfig {}) -> Latex
  return Latex { source = source style = style config = config }
end
