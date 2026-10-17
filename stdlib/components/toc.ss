import std:components/toc/style as { TocStyle }
import std:theme as theme
import std:internal/document as generated
import std:internal/style as styles
import std:components/box as boxes

type TocParts {
  root: Object
  title: Object
  list: Object
  background: Object
}

fn toc_parts(title_text: String, style: TocStyle = theme::current_theme().toc) -> TocParts
  let title = styles::text_object(title_text, "label", style.title)
  let list = generated::toc_obj()
  styles::apply_text_block_style(list, style.body)
  ~ list.top == title.bottom - 34
  ~ list.left == title.left
  let framed = boxes::box_parts(list, style.chrome)
  return TocParts { root = group(title, framed.root) title = title list = list background = framed.background }
end

fn/! toc(title_text: String, style: TocStyle = theme::current_theme().toc) -> Object
  return toc_parts(title_text, style).root
end
