import "./theme" as deck
import "./components" as *

document
  theme!(deck::theme)
end

page title
  cover!("My presentation", "Your name")
end

page text_and_code
  let title = heading! "Text and code"

  let body = text! <<
  **Markdown** supports emphasis and lists.

  - One short point.
  - Another short point.
  >>

  let command = code! "ss render --project . --output deck.pdf"

  ~ title.left == page.left + 80
  ~ title.top == page.top - 56
  ~ body.top == title.bottom - 32
  ~ command.top == body.bottom - 32

  footnote!("Source: add a reference here.")
  note! "Add speaker notes here."
end

page composition
  let title = heading! "Two columns"

  let row = (
    text! "Left column"
    |=| text! "Right column"
  ) with { gap = 48 }

  ~ title.left == page.left + 80
  ~ title.top == page.top - 56
  ~ row.left == page.left + 80
  ~ row.right == page.right - 80
  ~ row.top == title.bottom - 48
end
