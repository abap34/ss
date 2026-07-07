import std:core/classes as classes
import std:core/components as components

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

fn annotate_with_style!(source_text: String, target_text: String, note_text: String, style: MarkedCalloutStyle) -> Object
  return components::marked_callout!(source_text, target_text, note_text, style)
end

fn annotate_down_with_style!(source_text: String, target_text: String, note_text: String, style: MarkedCalloutStyle) -> Object
  return components::marked_callout!(source_text, target_text, note_text, style with {
    rises = false
  })
end
