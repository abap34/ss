import std:theme/types
import std:code/palettes as render

fn text_object(content: String, role: String, style: TextBlockStyle) -> Object
  let target = new(content, role, "text")
  return apply_text_block_style(target, style)
end

fn apply_text_block_style(target: Object, style: TextBlockStyle) -> Object
  target.text = style.text
  target.layout = style.layout
  target.underline = style.underline
  target.markdown_headings = style.headings
  return target
end

fn markdown_heading_style(style: TextBlockStyle) -> MarkdownHeadingStyle
  return MarkdownHeadingStyle {
    text = style.text
  }
end

fn markdown_text_style(theme: Theme) -> TextBlockStyle
  return theme.body with {
    text = render::text_with_code_theme(theme.body.text, theme.code.highlight)
    headings = MarkdownHeadingStyles {
      h1 = markdown_heading_style(theme.h1)
      h2 = markdown_heading_style(theme.h2)
      h3 = markdown_heading_style(theme.h3)
      h4 = markdown_heading_style(theme.h4)
      h5 = markdown_heading_style(theme.h5)
      h6 = markdown_heading_style(theme.h6)
    }
  }
end

fn apply_markdown_text_style(target: Object, theme: Theme) -> Object
  apply_text_block_style(target, markdown_text_style(theme))
  target.code = theme.code.highlight.code
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
