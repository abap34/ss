import std:math/types as { MathFit, LatexEngine, LatexStyle, LatexConfig }
import std:math/content as { Latex, Math }
import std:math/style as { LatexBlockStyle }

fn/! math(source: String, style: LatexBlockStyle = LatexBlockStyle {}, config: LatexConfig = LatexConfig {}) -> Math
  return Math { source = source style = style config = config }
end

fn latex_engine(engine: LatexEngine) -> Void
  extend_render_env(docctx(), "set", "latex.engine", engine)
end

fn page_latex_engine(engine: LatexEngine) -> Void
  extend_render_env(pagectx(), "set", "latex.engine", engine)
end

fn latex_preamble(src: String) -> Void
  extend_render_env(docctx(), "add", "latex.preamble", src)
end

fn page_latex_preamble(src: String) -> Void
  extend_render_env(pagectx(), "add", "latex.preamble", src)
end

fn latex_preamble_file(path: String) -> Void
  extend_render_env(docctx(), "add", "latex.preamble.file", path)
end

fn page_latex_preamble_file(path: String) -> Void
  extend_render_env(pagectx(), "add", "latex.preamble.file", path)
end

fn/! latex(source: String, style: LatexBlockStyle = LatexBlockStyle {}, config: LatexConfig = LatexConfig {}) -> Latex
  return Latex { source = source style = style config = config }
end
