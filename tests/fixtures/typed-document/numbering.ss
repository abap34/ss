import std:document as doc
import std:text as words
import std:components/toc as contents

type Claim {
  series: Number
  title: String
}

type WrappedHeading { value: doc::Heading }
fn display(self: Placed<WrappedHeading>) -> doc::Heading = self.value.value

fn claim_number(item: Placed<Claim>) -> String
  let series = item.value.series
  let items = filter(select<Claim>(item.document), (candidate: Placed<Claim>) |-> candidate.value.series == series)
  return str(doc::number_of(item, items) ?? 0)
end

fn display(self: Placed<Claim>) -> words::Text
  return words::text("Claim " ++ claim_number(self) ++ ": " ++ self.value.title)
end

fn page_label(page: Page, document: Document) -> String = str(page_index(page) - 1)

const reused: Claim = Claim { series = 1 title = "Shared" }
const unplaced: doc::Heading = doc::heading("Unused")
const unused_toc: contents::Toc = contents::toc("Unused")
const unused_number: doc::PageNumber = doc::pageno()

page overview
  let all = select<Claim>(docctx())
  let first_claim = first(all)
  words::text!("See claim " ++ claim_number(first_claim) ++ " on page " ++ page_label(first_claim.page, first_claim.document))
  words::text!("Absent: " ++ str(doc::number_of(first_claim, all - all) ?? -1))
  let toc = contents::toc("Overview", contents::TocStyle {}, page_label, (h: Placed<doc::Heading>) |-> h.value.level <= 2)
  place!(toc)
end

page body
  doc::heading!("Main section")
  place!(reused || Claim { series = 2 title = "Other series" } || reused)
  place!(WrappedHeading { value = doc::heading("Subsection", 2) })
end
