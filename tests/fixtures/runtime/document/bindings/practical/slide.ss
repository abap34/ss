import "./theme" as deck
import "./components" as ui

document
  theme!(document_style)
  ui::add_pageno_all!(document)
  let document = docctx()
end

page overview
  toc!("Contents")
  text!(join(claims, ", ", (item: Placed<ui::Claim>) |-> item.value.title))
  let claims = select<ui::Claim>(docctx())
end

page method
  theme!(page_style)
  let description = text!(format(title.value.title))
  let format = (value: String) |-> prefix ++ value
  let prefix = "Read "
  let title = heading!("Method")
  let claim = place!(ui::Claim { title = "Setup" })
  ui::footnote!("Method note")
  let page_style = deck::regular()
end

page result
  ~ content.left == page.left + 72
  ~ content.top == page.top - 72
  let content = group!(title, claim)
  let title = heading!("Results")
  let claim = place!(ui::Claim { title = "Result" })
  theme!(page_style)
  let page_style = deck::large()
end

page staged
  stages phase { 1:3 }
  text!(label.value.content.source ++ " alias")
  show phase >= 2
    let label = text!("Stage " ++ str(phase))
  end
  theme!(page_style)
  let page_style = deck::regular() with { text.size = 18 + phase }
end

document
  let document_style = deck::regular()
end
