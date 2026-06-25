import std:core/components as *

record TextBlockStyle {
  text: TextStyle = TextStyle {}
  layout: LayoutStyle = LayoutStyle {}
  underline: UnderlineStyle = UnderlineStyle {}
}

record ChromeBlockStyle {
  chrome: ChromeStyle = ChromeStyle {}
  layout: LayoutStyle = LayoutStyle {}
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
}

extend Doc {
  theme: Theme? = none
}

fn apply_text_block(obj: Object, style: TextBlockStyle) -> Object
  apply_text(obj, style.text)
  apply_layout(obj, style.layout)
  apply_underline(obj, style.underline)
  return obj
end

fn apply_code_block(obj: Object, style: CodeBlockStyle) -> Object
  apply_text(obj, style.text)
  apply_layout(obj, style.layout)
  code_theme(obj, style.highlight)
  return obj
end

fn apply_figure_block(obj: Object, style: FigureBlockStyle) -> Object
  apply_text(obj, style.text)
  apply_layout(obj, style.layout)
  return obj
end

fn apply_asset_block(obj: Object, style: AssetBlockStyle) -> Object
  apply_layout(obj, style.layout)
  apply_asset(obj, style.asset)
  return obj
end
