import std:math/types as { MathFit, LatexEngine, LatexStyle, LatexConfig }
import std:math/content as { Latex }
import std:math/style as { LatexBlockStyle }
import std:internal/objects as objects

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

fn/! latex(text_value: String, scale: Number = 1) -> Object
  let obj = objects::latex_obj(text_value)
  obj.latex.scale = scale
  return obj
end
