import std:themes/default as *

;; Synthetic regression examples. No content is taken from a real slide deck.
const column_width: Number = 1000
const column_policy: LayoutPolicy = LayoutPolicy.top

fn card(title: String, detail: String) -> Object
  let result = text("## " ++ title ++ "

" ++ detail)
  result.text.size = 20
  result.text.line_height = 27
  result.chrome.fill = c"#eff6ff"
  result.chrome.stroke = c"#2563eb"
  result.chrome.pad_x = 16
  result.chrome.pad_y = 12
  ~ result.width == 300
  ~ result.height == 170
  return result
end

page columns
  vflow(column_policy)
  head!("A description beside two supporting blocks")
  let description = text <<
## Collection notes

A synthetic paragraph explains how a small collection is checked before processing.

- Read the input records.
- Keep the original ordering.
- Report missing values clearly.
>>
  let upper = text <<
## Input summary

Twelve sample records arrive in three small batches. The labels are deliberately invented.
>>
  let lower = text <<
## Output summary

Each batch produces one compact report with a count and a short explanation.
>>
  upper.chrome.fill = c"#eff6ff"
  lower.chrome.fill = c"#f0fdf4"
  let content = description |=| (upper /=/ lower)
  ~ content.width == column_width
  ~ content.height == 440
  ~ content.left == page.left + 120
  ~ content.top == page.top - 180
  place!(content)
end

page matrix
  head!("Four blocks with nested padding")
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
  let left = a /=/ b
  let right = c /=/ d
  left.chrome.pad_x = 10
  left.chrome.pad_y = 6
  right.chrome.pad_x = 10
  right.chrome.pad_y = 6
  let content = left |=| right
  content.chrome.pad_x = 12
  content.chrome.pad_y = 8
  content.chrome.stroke = c"#94a3b8"
  ~ content.width == 1000
  ~ content.height == 440
  ~ content.left == page.left + 120
  ~ content.top == page.top - 180
  place!(content)
end

page table_code
  head!("A wrapped table and a short program")
  let table = text <<
| stage | observation |
| --- | --- |
| intake | Several small batches share the same source identifier. |
| review | A second pass checks ordering and missing entries. |
>>
  ~ table.width == 484
  let table_note = note("Table note: all entries are invented for this test.")
  ~ table_note.width == 484
  ~ table_note.left == table.left
  ~ table_note.top == table.bottom - 20
  let program_text = <<
records = read_batch()
valid = check(records)
write_report(valid)
>>
  let program = code(program_text, "python")
  ~ program.width == 484
  let code_note = note("Program note: validation happens before report generation.")
  ~ code_note.width == 484
  ~ code_note.left == program.left
  ~ code_note.top == program.bottom - 20
  let content = group(table, table_note) |=| group(program, code_note)
  ~ content.width == 1000
  ~ content.height == 440
  ~ content.left == page.left + 120
  ~ content.top == page.top - 180
  place!(content)
end

page flow
  vflow(LayoutPolicy.top)
  title!("A heading followed by ordinary document flow")
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
end

page image_caption
  head!("A diagram with a caption and a side note")
  let diagram = image("diagram.svg")
  ~ diagram.width == 640
  let caption = note("Diagram caption: the three invented bars illustrate increasing counts and have no connection to measured data.")
  ~ caption.width == 640
  ~ caption.left == diagram.left
  ~ caption.top == diagram.bottom - 20
  let annotation = text <<
## Reading the diagram

Each bar uses the same baseline. The caption stays below the complete image.
>>
  ~ annotation.width == 280
  ~ annotation.left == diagram.right + 32
  ~ annotation.center_y == diagram.center_y
  let content = group(diagram, caption, annotation)
  ~ content.left == page.left + 120
  ~ content.top == page.top - 170
  place!(content)
end

page cards
  head!("Three cards inside a movable ordinary group")
  let a = card("Collect", "Read a small batch of records.")
  let b = card("Transform", "Preserve the order while checking entries.")
  let c = card("Inspect", "Review the resulting report.")
  ~ b.left == a.right + 24
  ~ b.top == a.top
  ~ c.left == b.right + 24
  ~ c.top == a.top
  let row = group(a, b, c)
  ~ row.left == page.left + 150
  ~ row.top == page.top - 210
  place!(row)
  let summary = text!("Card summary: all three steps share one row, with a separate explanation underneath.")
  ~ summary.width == 948
  ~ summary.left == row.left
  ~ summary.top == row.bottom - 28
end

document
  pagenos!()
end
