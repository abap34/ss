import std:core/classes as classes
import std:core/components as components
import std:core/generated as generated

record TextBlockStyle {
  text: TextStyle = TextStyle {}
  layout: LayoutStyle = LayoutStyle {}
  underline: UnderlineStyle = UnderlineStyle {}
}

record RuleBlockStyle {
  rule: RuleStyle = RuleStyle {}
  layout: LayoutStyle = LayoutStyle {}
}

record CodeBlockStyle {
  text: TextStyle = TextStyle {}
  layout: LayoutStyle = LayoutStyle {}
  highlight: CodeHighlightTheme = CodeHighlightTheme {}
  chrome: ChromeStyle = ChromeStyle {}
}

record AssetBlockStyle {
  layout: LayoutStyle = LayoutStyle {}
  asset: AssetStyle = AssetStyle {}
  chrome: ChromeStyle = ChromeStyle {}
}

record FigureBlockStyle {
  text: TextStyle = TextStyle {}
  layout: LayoutStyle = LayoutStyle {}
  chrome: ChromeStyle = ChromeStyle {}
}

record TocStyle {
  title: TextBlockStyle = TextBlockStyle {}
  body: TextBlockStyle = TextBlockStyle {}
  chrome: ChromeStyle = ChromeStyle {}
}

record CoverStyle {
  title: TextBlockStyle = TextBlockStyle {}
  subtitle: TextBlockStyle = TextBlockStyle {}
  author: TextBlockStyle = TextBlockStyle {}
  date: TextBlockStyle = TextBlockStyle {}
  accent: RuleBlockStyle = RuleBlockStyle {}
}

record GeneratedStyle {
  pageno: TextBlockStyle = TextBlockStyle {}
  footer: TextBlockStyle = TextBlockStyle {}
  watermark: TextBlockStyle = TextBlockStyle {}
}

record Theme {
  body: TextBlockStyle = TextBlockStyle {}
  h1: TextBlockStyle = TextBlockStyle {}
  h2: TextBlockStyle = TextBlockStyle {}
  h3: TextBlockStyle = TextBlockStyle {}
  h4: TextBlockStyle = TextBlockStyle {}
  h5: TextBlockStyle = TextBlockStyle {}
  h6: TextBlockStyle = TextBlockStyle {}
  head: TextBlockStyle = TextBlockStyle {}
  subhead: TextBlockStyle = TextBlockStyle {}
  note: TextBlockStyle = TextBlockStyle {}
  byline: TextBlockStyle = TextBlockStyle {}
  label: TextBlockStyle = TextBlockStyle {}
  citation: TextBlockStyle = TextBlockStyle {}
  code: CodeBlockStyle = CodeBlockStyle {}
  figure: FigureBlockStyle = FigureBlockStyle {}
  image: AssetBlockStyle = AssetBlockStyle {}
  pdf: AssetBlockStyle = AssetBlockStyle {}
  toc: TocStyle = TocStyle {}
  cover: CoverStyle = CoverStyle {}
  generated: GeneratedStyle = GeneratedStyle {}
  callout: MarkedCalloutStyle = MarkedCalloutStyle {}
}

extend Doc {
  theme: Theme? = none
}

fn set_theme!(theme_value: Theme) -> Void
  docctx().theme = theme_value
end

fn current_theme_or(default_value: Theme) -> Theme
  return docctx().theme ?? default_value
end

fn apply_text_block_style(target: Object, style: TextBlockStyle) -> Object
  set_prop(target, "text", style.text)
  set_prop(target, "layout", style.layout)
  set_prop(target, "underline", style.underline)
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
  set_prop(target, "markdown_headings", headings)
  return target
end

fn apply_markdown_text_style(target: Object, theme: Theme) -> Object
  apply_text_block_style(target, theme.body)
  apply_markdown_heading_styles(target, theme)
  return target
end

fn apply_figure_block_style(target: Object, style: FigureBlockStyle) -> Object
  set_prop(target, "text", style.text)
  set_prop(target, "layout", style.layout)
  set_prop(target, "chrome", style.chrome)
  return target
end

fn apply_code_block_style(target: Object, style: CodeBlockStyle) -> Object
  set_prop(target, "text", style.text)
  set_prop(target, "layout", style.layout)
  set_prop(target, "chrome", style.chrome)
  return target
end

fn apply_asset_block_style(target: Object, style: AssetBlockStyle) -> Object
  set_prop(target, "layout", style.layout)
  set_prop(target, "asset", style.asset)
  set_prop(target, "chrome", style.chrome)
  return target
end

fn apply_rule_block_style(target: Object, style: RuleBlockStyle) -> Object
  set_prop(target, "rule", style.rule)
  set_prop(target, "layout", style.layout)
  return target
end

fn byline_with_style(text_value: String, style: TextBlockStyle) -> Object
  return apply_text_block_style(components::byline(text_value), style)
end

fn label_with_style(text_value: String, style: TextBlockStyle) -> Object
  return apply_text_block_style(components::label(text_value), style)
end

fn citation_with_style(target: Object, number: Number, reference_text: String, style: TextBlockStyle) -> Object
  return components::citation_with(target, number, reference_text, (ref: Object) |-> apply_text_block_style(ref, style))
end

fn pageno_with_style(style: TextBlockStyle) -> Object
  return generated::pageno_obj((page_no: Object) |-> apply_text_block_style(page_no, style))
end

fn pagenos_with_style!(format: String?, style: TextBlockStyle) -> Void
  generated::mk_pagenos!(docctx(), format, (obj: Object) |-> apply_text_block_style(obj, style))
end

fn footers_with_style!(text_value: String, style: TextBlockStyle) -> Void
  generated::mk_footers!(docctx(), text_value, (obj: Object) |-> apply_text_block_style(obj, style))
end

fn watermark_with_style!(text_value: String, style: TextBlockStyle) -> Void
  generated::mk_marks!(docctx(), text_value, (obj: Object) |-> apply_text_block_style(obj, style))
end

fn annotate_with_style!(source_text: String, target_text: String, note_text: String, style: MarkedCalloutStyle) -> Object
  return components::marked_callout!(source_text, target_text, note_text, style)
end

fn annotate_down_with_style!(source_text: String, target_text: String, note_text: String, style: MarkedCalloutStyle) -> Object
  return components::marked_callout!(source_text, target_text, note_text, style with {
    rises = false
  })
end
