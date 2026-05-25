import std:themes/default

document
pagenos("{page} / {total}")
footers("component sample")
logos("assets/sample-logo.svg", 0.18)
need_titles()
end

page component_cover
cover("Components", "Common objects and document generation", "ss")
end

page component_text
let title = head("Text and markdown")
let body = text <<
Text accepts Markdown.

- lists
- `inline code`
- links such as [reference](https://example.com)

Citation marker [1] is rewritten by the citation helper.
>>
let note_block = note("A note is a text object with note role and theme defaults.")
let cap = figure("Figure 1. Text, markdown, note, and citation")

citation(body, 1, "Example reference")
below(body, title, 32)
below(note_block, body, 24)
below(cap, note_block, 18)
same_l(body, title, 0)
same_l(note_block, body, 0)
same_l(cap, body, 0)
end

page component_code_math
let title = head("Code and math")
let sample = code("""
fn add(left: number, right: number) -> number
  return left + right
end
""", "ss")
let eq = tex("\\sum_{i=1}^{n} i = \\frac{n(n+1)}{2}", 1.0)
let cap = figure("Figure 2. Code and LaTeX math")

below(sample, title, 32)
below(eq, sample, 28)
below(cap, eq, 16)
same_l(sample, title, 0)
same_l(eq, sample, 0)
same_l(cap, sample, 0)
end

page component_assets
let title = head("Assets and chrome")
let logo_image = image("assets/sample-logo.svg", 0.55)
let pdf_obj = pdf("assets/sample-card.pdf", 0.85)
let line = rule("custom")
let panel_box = panel(style("custom"))
let caption = figure("Figure 3. SVG image, PDF asset, rule, and panel")

rule_l(line, "0.2745,0.5098,0.7059", "2", "")
box(panel_box, "0.96,0.98,1", "0.72,0.78,0.86", "1", "8")

below(logo_image, title, 32)
below(pdf_obj, logo_image, 20)
below(line, pdf_obj, 24)
below(caption, line, 18)
same_l(logo_image, title, 0)
same_l(pdf_obj, logo_image, 0)
same_l(line, logo_image, 0)
same_l(caption, logo_image, 0)
fix_w(line, 520)
surround(panel_box, group(logo_image, pdf_obj, line), 18, 14)
end

page component_toc
let title = head("Table of contents")
let list = toc_obj()
fix_h(list, 190)
below(list, title, 32)
end
