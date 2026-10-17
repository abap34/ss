import std:internal/classes
import std:text/style
import std:components/callout/style

type HeadStyle = record {
  title: TextBlockStyle = TextBlockStyle {}
  rule: RuleBlockStyle = RuleBlockStyle {}
  top: Number = 56
  gap: Number = 0
}

type RuleBlockStyle = record {
  rule: RuleStyle = RuleStyle {}
  layout: LayoutStyle = LayoutStyle {}
}

type MarkedCalloutStyle = record {
  x: Number = 96
  top_y: Number = 220
  text: TextStyle = TextStyle {
    font = FontFace { family = "Helvetica" }
    code_font = FontFace { family = "monospace" }
    size = 25
    line_height = 34
    color = c"#111827"
  }
  target: TextStyle = TextStyle {
    font = FontFace { family = "Helvetica" weight = 700 }
    code_font = FontFace { family = "monospace" }
    size = 25
    line_height = 34
    color = c"#111827"
  }
  target_chrome: ChromeStyle = ChromeStyle {
    fill = none
    stroke = none
    line_width = 0
    radius = 0
    pad_x = 0
    pad_y = 0
  }
  callout_x: Number = 780
  callout_top_y: Number = 486
  callout_width: Number = 300
  callout: CalloutStyle = CalloutStyle {}
}
