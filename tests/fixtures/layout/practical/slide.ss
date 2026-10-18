import std:themes/default as *

;; Synthetic regression examples. No content is taken from a real slide deck.
const column_width: Number = 1000
const column_policy: LayoutPolicy = LayoutPolicy.top

const theme: Theme = default_theme()

type Card { title: String detail: String }
fn display(self: Placed<Card>) -> Group<PathShape, Text>
  return group(
    rectangle(300, 170, VectorStyle {
      fill = solid_fill(c"#eff6ff")
      stroke = solid_stroke(c"#2563eb", 1)
    }),
    text("## " ++ self.value.title ++ "

" ++ self.value.detail,
      theme.body with { text.size = 20 text.line_height = 27 })
  )
end

fn arrange_card(card: Placed<Card>) -> Void
  let panel = first(select<PathShape>(card))
  let body = first(select<Text>(card))
  ~ body.left == panel.left + 16
  ~ body.right == panel.right - 16
  ~ body.top == panel.top - 12
end

fn page_heading!(title: String) -> Void
  let heading = heading!(title, 1, theme.h1)
  ~ heading.left == page.left + 72
  ~ heading.top == page.top - 56
end

fn page_number!(p: Page) -> Void
  let number = place_on!(p, pageno(theme.page_number))
  ~ number.bottom == p.bottom + 20
  ~ number.right == p.right - 24
end

page columns
  vflow(column_policy)
  page_heading!("A description beside two supporting blocks")
  let description_content = <<
## Collection notes

A synthetic paragraph explains how a small collection is checked before processing.

- Read the input records.
- Keep the original ordering.
- Report missing values clearly.
>>
  let description = text(description_content, theme.body with { text.size = 24 })
  let upper = text <<
## Input summary

Twelve sample records arrive in three small batches. The labels are deliberately invented.
>>
  let lower = text <<
## Output summary

Each batch produces one compact report with a count and a short explanation.
>>
  let content = place!(description |=| (upper /=/ lower))
  ~ content.width == column_width
  ~ content.height == 440
  ~ content.left == page.left + 120
  ~ content.top == page.top - 180
  page_number!(pagectx())
end

page matrix
  page_heading!("Four blocks with nested padding")
  let a = text <<
## Observe

Record a small sample and note its source.
>>
  let b = text <<
## Compare

Check the sample against a fixed reference.
>>
  let c = text <<
## Explain

Describe the difference in plain language.
>>
  let d = text <<
## Review

Read the result and confirm the next step.
>>
  let content = place!(group(
    rectangle(1000, 440, VectorStyle { stroke = solid_stroke(c"#94a3b8", 1) }),
    group(rectangle(472, 424, VectorStyle { stroke = no_stroke() }), a, b),
    group(rectangle(472, 424, VectorStyle { stroke = no_stroke() }), c, d)
  ))
  let frame = first(children(content))
  let left = first(children(content) - selection(frame))
  let right = first(children(content) - selection(frame) - selection(left))
  let left_frame = first(children(left))
  let right_frame = first(children(right))
  let upper_left = first(children(left) - selection(left_frame))
  let lower_left = first(children(left) - selection(left_frame) - selection(upper_left))
  let upper_right = first(children(right) - selection(right_frame))
  let lower_right = first(children(right) - selection(right_frame) - selection(upper_right))
  ~ content.left == page.left + 120
  ~ content.top == page.top - 180
  ~ left_frame.left == frame.left + 12
  ~ right_frame.left == frame.center_x + 16
  ~ left_frame.top == frame.top - 8
  ~ right_frame.top == left_frame.top
  ~ upper_left.left == left_frame.left + 10
  ~ upper_left.right == left_frame.right - 10
  ~ upper_left.top == left_frame.top - 6
  ~ upper_left.bottom == left_frame.center_y + 16
  ~ lower_left.left == upper_left.left
  ~ lower_left.right == upper_left.right
  ~ lower_left.top == left_frame.center_y - 16
  ~ lower_left.bottom == left_frame.bottom + 6
  ~ upper_right.left == right_frame.left + 10
  ~ upper_right.right == right_frame.right - 10
  ~ upper_right.top == upper_left.top
  ~ upper_right.bottom == upper_left.bottom
  ~ lower_right.left == upper_right.left
  ~ lower_right.right == upper_right.right
  ~ lower_right.top == lower_left.top
  ~ lower_right.bottom == lower_left.bottom
  page_number!(pagectx())
end

page table_code
  page_heading!("A wrapped table and a short program")
  let table = text(<<
| stage | observation |
| --- | --- |
| intake | Several small batches share the same source identifier. |
| review | A second pass checks ordering and missing entries. |
>>, theme.body)
  let table_note = text("Table note: all entries are invented for this test.", theme.note)
  let program_text = <<
records = read_batch()
valid = check(records)
write_report(valid)
>>
  let program = code(program_text, "python", theme.code)
  let code_note = text("Program note: validation happens before report generation.", theme.note)
  let content = place!(((table // table_note) with { gap = 20 }) |=| ((program // code_note) with { gap = 20 }))
  let code_frame = first(select<Code>(content))
  ~ code_frame.width == 484
  ~ content.width == 1000
  ~ content.height == 440
  ~ content.left == page.left + 120
  ~ content.top == page.top - 180

  page_number!(pagectx())
end

page flow
  vflow(LayoutPolicy.top)
  heading!("A heading followed by ordinary document flow", 1, theme.h1)
  let intro = text!("Flow introduction: a longer paragraph should wrap naturally without pushing the next item into its last line.")
  ~ intro.width == 680
  let list = text! <<
- First, collect a small sample.
- Next, preserve its ordering.
- Finally, write a concise report.
>>
  ~ list.width == 680
  let conclusion = text!("Flow conclusion: each block remains separate and readable.")
  ~ conclusion.width == 680
  page_number!(pagectx())
end

page image_caption
  page_heading!("A diagram with a caption and a side note")
  let diagram_value = image("diagram.svg")
  let caption_value = text("Diagram caption: the three invented bars illustrate increasing counts and have no connection to measured data.", theme.note)
  let annotation_value = text <<
## Reading the diagram

Each bar uses the same baseline. The caption stays below the complete image.
>>
  let content = place!(((diagram_value // caption_value) with { gap = 20 }) || annotation_value)
  let column = first(children(content))
  let annotation = first(children(content) - selection(column))
  let diagram = first(children(column))
  let caption = first(children(column) - selection(diagram))
  ~ diagram.width == 640
  ~ caption.width == 640
  ~ annotation.width == 280
  ~ annotation.center_y == diagram.center_y
  ~ content.left == page.left + 120
  ~ content.top == page.top - 170
  page_number!(pagectx())
end

page cards
  page_heading!("Three cards inside a movable ordinary group")
  let first_card = Card { title = "Collect" detail = "Read a small batch of records." }
  let second_card = Card { title = "Transform" detail = "Preserve the order while checking entries." }
  let third_card = Card { title = "Inspect" detail = "Review the resulting report." }
  let pair = (first_card || second_card) with { gap = 24 }
  let row = place!((pair || third_card) with { gap = 24 })
  foreach(select<Card>(row), arrange_card)
  ~ row.left == page.left + 150
  ~ row.top == page.top - 210
  let summary = text!("Card summary: all three steps share one row, with a separate explanation underneath.")
  ~ summary.width == 948
  ~ summary.left == row.left
  ~ summary.top == row.bottom - 28
  page_number!(pagectx())
end
