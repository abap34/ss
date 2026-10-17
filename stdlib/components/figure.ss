import std:components/figure/style as { FigureBlockStyle }
import std:theme as theme
import std:text/types
import std:internal/style as styles

type FigureParts {
  root: Object
  body: Object
  caption: Object
}

fn figure_parts(body: Object, caption: String, style: FigureBlockStyle = theme::current_theme().figure, gap: Number = 12) -> FigureParts
  let label = new(caption, "label", "text")
  styles::apply_figure_block_style(label, style)
  label.semantics = SemanticStyle { role = SemanticRole.caption }
  ~ label.top == body.bottom - gap
  ~ label.left == body.left
  return FigureParts { root = group(body, label) body = body caption = label }
end

fn/! figure(body: Object, caption: String, style: FigureBlockStyle = theme::current_theme().figure, gap: Number = 12) -> Object
  return figure_parts(body, caption, style, gap).root
end
