import std:graphics/types
import std:math/types
import std:assets/types
import std:layout/types
import std:code/types
import std:text/types
import std:graphics/paint/types

type Doc = object {
  layout_h: LayoutPolicy = LayoutPolicy.left
  layout_h_center_offset: Number = 0
  layout_v: LayoutPolicy = LayoutPolicy.center
  layout_v_center_offset: Number = 0
  background_fill: Color? = none
  footer_text: String? = none
  logo_path: String? = none
  logo_scale: Number = 1
  watermark: String? = none
  math_align: Align = Align.center
  code_theme_plain_color: Color? = none
  code_theme_keyword_color: Color? = none
  code_theme_function_color: Color? = none
  code_theme_type_color: Color? = none
  code_theme_constant_color: Color? = none
  code_theme_number_color: Color? = none
  code_theme_variable_color: Color? = none
  code_theme_operator_color: Color? = none
  code_theme_comment_color: Color? = none
  code_theme_string_color: Color? = none
  code_theme_fill: Color? = none
  code_theme_stroke: Color? = none
}

type PageContext = object {
  base = Doc
}

type Flow = object {
  semantics: TextSemantics = TextSemantics {}
  render_kind: RenderKind = RenderKind.text
  layout: LayoutStyle = LayoutStyle {}
  chrome: ChromeStyle = ChromeStyle {}
  link_id: String = ""
}

type Text = object {
  base = Flow

  text: TextStyle = TextStyle {}
  markdown_headings: MarkdownHeadingStyles = MarkdownHeadingStyles {}
  code: CodeColors = CodeColors {}
  underline: UnderlineStyle = UnderlineStyle {}
  math_align: Align = Align.center
}

type Title = object {
  base = Text
  roles = ["title"]
  semantics: TextSemantics = TextSemantics { role = SemanticRole.heading, heading_level = 1 }

  text: TextStyle = TextStyle {
    size = 34
    color = c"0,0,0.0353"
  }
  layout: LayoutStyle = LayoutStyle {
    spacing_after = 58
    x = 72
    right_inset = 72
  }
}

type Sub = object {
  base = Text
  roles = ["subtitle"]
  semantics: TextSemantics = TextSemantics { role = SemanticRole.heading, heading_level = 2 }

  text: TextStyle = TextStyle {
    size = 18
    color = c"0,0,0.0353"
  }
  layout: LayoutStyle = LayoutStyle {
    spacing_after = 38
    x = 96
    right_inset = 96
  }
}

type Body = object {
  base = Text
  roles = ["body"]

  text: TextStyle = TextStyle {
    parse = TextParseMode.block
    size = 20
    color = c"0,0,0.0353"
  }
  layout: LayoutStyle = LayoutStyle {
    spacing_after = 32
    x = 96
    right_inset = 96
  }
}

type Note = object {
  base = Body
  roles = ["note"]

  layout: LayoutStyle = LayoutStyle {
    spacing_after = 28
    x = 96
    right_inset = 96
  }
}

type By = object {
  base = Text
  roles = ["byline"]

  text: TextStyle = TextStyle {
    size = 20
    color = c"0.2745,0.5098,0.7059"
  }
  layout: LayoutStyle = LayoutStyle {
    spacing_after = 18
    x = 72
    right_inset = 72
  }
}

type Lab = object {
  base = Text
  roles = ["label"]

  text: TextStyle = TextStyle {
    size = 14
    color = c"0.2745,0.5098,0.7059"
  }
  layout: LayoutStyle = LayoutStyle {
    spacing_after = 0
    x = 72
    right_inset = 72
    wrap = WrapMode.off
  }
}

type Cite = object {
  base = Text
  roles = ["citation"]

  text: TextStyle = TextStyle {
    parse = TextParseMode.inline
    size = 13
    color = c"0.58,0.58,0.58"
    link_color = c"0.58,0.58,0.58"
  }
  layout: LayoutStyle = LayoutStyle {
    spacing_after = 0
    x = 120
    right_inset = 90
    wrap = WrapMode.off
  }
}

type Code = object {
  base = Text
  roles = ["code"]
  semantics: TextSemantics = TextSemantics { role = SemanticRole.code }

  render_kind: RenderKind = RenderKind.code
  text: TextStyle = TextStyle {
    parse = TextParseMode.none
    font = FontFace { family = "monospace" }
    code_font = FontFace { family = "monospace" }
    size = 15
    color = c"0.12,0.12,0.12"
  }
  layout: LayoutStyle = LayoutStyle {
    spacing_after = 32
    x = 102
    right_inset = 102
    wrap = WrapMode.off
  }
  language: String = "plain"
  code: CodeColors = CodeColors {
    plain = c"0.12,0.12,0.12"
    keyword = c"#cf222e"
    function = c"#8250df"
    type_name = c"#953800"
    constant = c"#0550ae"
    number = c"#0550ae"
    variable = c"0.12,0.12,0.12"
    operator = c"#0550ae"
    comment = c"0.3059,0.5412,0.3608"
    string = c"0.6980,0.2549,0.2157"
  }
}

type Latex = object {
  base = Text
  roles = ["latex"]

  latex: LatexStyle = LatexStyle {}
  render_kind: RenderKind = RenderKind.latex
  text: TextStyle = TextStyle {
    parse = TextParseMode.none
    font = FontFace { family = "Courier" }
    size = 18
    color = c"0,0,0.0353"
  }
  layout: LayoutStyle = LayoutStyle {
    spacing_after = 32
    x = 102
    right_inset = 102
    wrap = WrapMode.off
  }
}

type Fig = object {
  base = Text
  roles = ["figure"]
  semantics: TextSemantics = TextSemantics { role = SemanticRole.figure }

  asset: AssetStyle = AssetStyle {}
  text: TextStyle = TextStyle {
    font = FontFace { family = "Courier" }
    size = 16
    color = c"0.18,0.18,0.18"
  }
  layout: LayoutStyle = LayoutStyle {
    spacing_after = 32
    x = 102
    right_inset = 102
    wrap = WrapMode.off
  }
}

type Img = object {
  base = Fig
  roles = ["image"]

  render_kind: RenderKind = RenderKind.raster_asset
  text: TextStyle = TextStyle {
    parse = TextParseMode.none
    font = FontFace { family = "Courier" }
    size = 16
    color = c"0.18,0.18,0.18"
  }
}

type Pdf = object {
  base = Fig
  roles = ["pdf"]

  render_kind: RenderKind = RenderKind.vector_asset
  text: TextStyle = TextStyle {
    parse = TextParseMode.none
    font = FontFace { family = "Courier" }
    size = 16
    color = c"0.18,0.18,0.18"
  }
}

type Icon = object {
  base = Fig
  roles = ["icon"]

  render_kind: RenderKind = RenderKind.vector_asset
  asset: AssetStyle = AssetStyle {
    tint = c"#374151"
  }
  text: TextStyle = TextStyle {
    parse = TextParseMode.none
  }
  layout: LayoutStyle = LayoutStyle {
    spacing_after = 0
    x = 0
    right_inset = 0
    wrap = WrapMode.off
  }
}

type Panel = object {
  base = Flow
  roles = ["panel"]

  render_kind: RenderKind = RenderKind.chrome_only
  layout: LayoutStyle = LayoutStyle {
    font_size = 4
    line_height = 4
    spacing_after = 0
    x = 72
    right_inset = 72
    wrap = WrapMode.off
  }
}

type Rule = object {
  base = Panel
  roles = ["rule"]

  rule: RuleStyle = RuleStyle {
    stroke = c"#d0d7de"
  }
  layout: LayoutStyle = LayoutStyle {
    font_size = 4
    line_height = 4
    spacing_after = 24
    x = 72
    right_inset = 72
    wrap = WrapMode.off
  }
}

type VectorShape = object {
  base = Panel
  roles = ["vector_path"]

  path: Path? = none
  fill: FillStyle = FillStyle {}
  stroke: VectorStrokeStyle = VectorStrokeStyle {}
  marker_start: MarkerStyle? = none
  marker_end: MarkerStyle? = none
  render_kind: RenderKind = RenderKind.vector_path
  layout: LayoutStyle = LayoutStyle {
    font_size = 1
    line_height = 1
    spacing_after = 0
    x = 72
    right_inset = 72
    wrap = WrapMode.off
  }
}

type Connector = object {
  base = Panel
  roles = ["connector"]

  connector: ConnectorStyle = ConnectorStyle {}
  render_kind: RenderKind = RenderKind.connector
  layout: LayoutStyle = LayoutStyle {
    font_size = 1
    line_height = 1
    spacing_after = 0
    x = 0
    right_inset = 0
    wrap = WrapMode.off
  }
}

type Footer = object {
  base = Text
  roles = ["footer"]

  text: TextStyle = TextStyle {
    size = 12
    color = c"0.42,0.42,0.42"
  }
  layout: LayoutStyle = LayoutStyle {
    spacing_after = 0
    wrap = WrapMode.off
  }
}

type Logo = object {
  base = Img
  roles = ["logo"]

  asset: AssetStyle = AssetStyle {}
  layout: LayoutStyle = LayoutStyle {
    spacing_after = 32
    x = 102
    right_inset = 102
    wrap = WrapMode.off
  }
}

type Watermark = object {
  base = Text
  roles = ["watermark"]

  text: TextStyle = TextStyle {
    size = 72
    color = c"0.85,0.85,0.85"
  }
  layout: LayoutStyle = LayoutStyle {
    spacing_after = 0
    wrap = WrapMode.off
  }
}

type ObjectGroup = object {
  base = Flow
  roles = ["group"]

  align_children_y: Bool = false
  split_axis: SplitAxis = SplitAxis.none
  join_axis: SplitAxis = SplitAxis.none
  split_gap: Number = 32
  render_kind: RenderKind = RenderKind.chrome_only
  layout: LayoutStyle = LayoutStyle {
    font_size = 4
    line_height = 4
    spacing_after = 0
    x = 72
    right_inset = 72
    wrap = WrapMode.off
  }
}
