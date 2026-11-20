import "./theme" as deck
import "./components" as ui

const repeated: Text = text("Repeated")

page overview
  toc!("Contents")
  text!(join(select<ui::Card>(docctx()), ", ", ui::title))
  ui::footnote!("Overview note")
end

page method
  let a = ui::card!("Method", &result::b)
  heading!("Method")
  let content = group!(a)
  place!(repeated)
  pageno!()
end

page result
  let b = ui::card!("Result", &method::a)
  heading!("Results")
  place!(repeated)
  theme!(deck::large)
  pageno!()
end

page staged
  stages phase { 1:3 }
  let a = ui::card!("First " ++ str(phase), &staged::b)
  let b = ui::card!("Second " ++ str(phase), &a)
  theme!(deck::regular with { text.size = 17 + phase })
  pageno!()
end

document
  theme!(deck::regular)
end
