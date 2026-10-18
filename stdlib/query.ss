fn previous_page(page_value: Page) -> Page?
  return select(page_value, "previous_page")
end

fn filter<T>(items: Selection<T>, predicate: T -> Bool) -> Selection<T>
  return selection_filter(items, predicate)
end

fn selection<T>(item: T) -> Selection<T>
  return select(item, "self_placement")
end

fn children(base: Placement) -> Selection<Placement>
  return select(base, "children")
end

fn descendants(base: Placement) -> Selection<Placement>
  return select(base, "descendants")
end

fn doc_pages() -> Selection<Page>
  return select(docctx(), "document_pages")
end

fn pages(doc: Document) -> Selection<Page>
  return select(doc, "document_pages")
end
