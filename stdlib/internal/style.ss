import std:theme/types
import std:code/palettes as render

fn text_object(content: String, role: String, style: TextBlockStyle) -> Object
  let target = new(content, role, "text")
  return apply_text_block_style(target, style)
end

fn rule_object(style: RuleBlockStyle) -> Object
  let target = new("", "rule", "text")
  return apply_rule_block_style(target, style)
end

fn apply_text_block_style(target: Object, style: TextBlockStyle) -> Object
  target.text = style.text
  target.layout = style.layout
  target.underline = style.underline
  return target
end

fn markdown_heading_style(style: TextBlockStyle) -> MarkdownHeadingStyle
  return MarkdownHeadingStyle {
    text = style.text
  }
end

fn apply_markdown_heading_styles(target: Object, theme: Theme) -> Object
  let headings = MarkdownHeadingStyles {
    h1 = markdown_heading_style(theme.h1)
    h2 = markdown_heading_style(theme.h2)
    h3 = markdown_heading_style(theme.h3)
    h4 = markdown_heading_style(theme.h4)
    h5 = markdown_heading_style(theme.h5)
    h6 = markdown_heading_style(theme.h6)
  }
  target.markdown_headings = headings
  return target
end

fn apply_markdown_text_style(target: Object, theme: Theme) -> Object
  apply_text_block_style(target, theme.body with { text = render::text_with_code_theme(theme.body.text, theme.code.highlight) })
  target.code = theme.code.highlight.code
  apply_markdown_heading_styles(target, theme)
  return target
end

fn apply_figure_block_style(target: Object, style: FigureBlockStyle) -> Object
  target.text = style.text
  target.layout = style.layout
  target.chrome = style.chrome
  return target
end

fn apply_code_block_style(target: Object, style: CodeBlockStyle) -> Object
  target.text = render::text_with_code_theme(style.text, style.highlight)
  target.code = style.highlight.code
  target.layout = style.layout
  target.chrome = style.chrome
  return target
end

fn apply_asset_block_style(target: Object, style: AssetBlockStyle) -> Object
  target.layout = style.layout
  target.asset = style.asset
  target.chrome = style.chrome
  return target
end

fn apply_rule_block_style(target: Object, style: RuleBlockStyle) -> Object
  target.rule = style.rule
  target.layout = style.layout
  return target
end
