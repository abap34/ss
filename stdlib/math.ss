import std:math/types as { MathFit, LatexEngine, LatexConfig }
import std:math/content as { Latex, Math }
import std:assets/style as { ImageStyle }

fn/! math(source: String, style: ImageStyle? = none, config: LatexConfig = LatexConfig {}, min_height: Number = 30) -> Math
  return Math { source = source style = style config = config min_height = min_height }
end

fn/! latex(source: String, style: ImageStyle? = none, config: LatexConfig = LatexConfig {}, min_height: Number = 30) -> Latex
  return Latex { source = source style = style config = config min_height = min_height }
end
