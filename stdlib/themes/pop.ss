import std:theme/types

import std:themes/default as base

fn default_theme(options: ThemeOptions = ThemeOptions {}) -> Theme
  let panel = ChromeStyle {
    fill = c"1,0.9647,0.9294"
    stroke = c"1,0.7373,0.3843"
    line_width = 1.4
    radius = 16
    pad_x = 14
    pad_y = 12
  }
  return base::default_theme(options) with {
    body.text.size = 20
    body.text.line_height = 28
    body.text.color = options.text_color ?? c"0.1569,0.1333,0.2196"
    body.text.markdown.code.size = 18
    body.text.markdown.code.line_height = 24
    body.text.markdown.code.chrome.pad_x = 14
    body.text.markdown.code.chrome.pad_y = 12
    body.text.markdown.code.chrome.fill = c"1,0.9647,0.9294"
    body.text.markdown.code.chrome.stroke = c"1,0.7373,0.3843"
    body.text.markdown.code.chrome.line_width = 1.4
    body.text.markdown.code.chrome.radius = 16
    body.text.markdown.quote.color = c"0.1569,0.1333,0.2196"
    body.text.markdown.quote.inset = 12
    body.text.markdown.quote.pad_x = 18
    body.text.markdown.quote.pad_y = 12
    body.text.markdown.quote.fill = c"1,0.9647,0.9294"
    body.text.markdown.quote.radius = 14
    body.text.markdown.quote.bar_color = c"1,0.3765,0.5098"
    body.text.markdown.quote.bar_width = 5
    h1.text.size = 36
    h1.text.line_height = 42
    h1.text.color = options.text_color ?? c"1,0.3765,0.5098"
    h1.layout.spacing_after = 46
    h1.layout.x = 72
    h1.layout.right_inset = 72
    h2.text.size = 22
    h2.text.line_height = 30
    h2.text.color = options.text_color ?? c"0.1569,0.1333,0.2196"
    h2.text.font.weight = 400
    h2.layout.spacing_after = 22
    h2.layout.x = 78
    h2.layout.right_inset = 78
    head.title.text.size = 36
    head.title.text.line_height = 42
    head.title.text.color = options.accent_color ?? c"1,0.3765,0.5098"
    head.title.layout.spacing_after = 46
    head.top = 98
    note.layout.x = 124
    note.layout.right_inset = 124
    code.layout.x = 108
    code.layout.right_inset = 108
    code.chrome = panel with { pad_x = 18 pad_y = 14 }
    figure.layout.x = 108
    figure.layout.right_inset = 108
    figure.chrome = panel
    image.layout.x = 108
    image.layout.right_inset = 108
    image.chrome = panel
    pdf.layout.x = 108
    pdf.layout.right_inset = 108
    pdf.chrome = panel
    toc.title.text.size = 36
    toc.title.text.line_height = 42
    toc.title.text.color = options.accent_color ?? c"1,0.3765,0.5098"
    toc.title.layout.spacing_after = 46
    toc.chrome = panel
    callout.text.size = 20
    callout.text.line_height = 28
    callout.text.color = options.text_color ?? c"0.1569,0.1333,0.2196"
    callout.target.size = 20
    callout.target.line_height = 28
    callout.target.color = options.accent_color ?? c"0.4745,0.3765,1"
    callout.target.font.weight = 700
    callout.target_chrome = panel with { radius = 12 pad_x = 8 pad_y = 4 }
    callout.callout.stroke = options.accent_color ?? c"1,0.3765,0.5098"
    callout.callout.line_width = 2.4
    callout.callout.marker_size = 14
    callout.callout.chrome = panel with { radius = 14 pad_x = 18 pad_y = 12 }
    callout.callout.text.size = 18
    callout.callout.text.line_height = 27
    callout.callout.text.color = options.muted_color ?? c"0.1569,0.1333,0.2196"
  }
end
