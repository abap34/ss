fn previous_page() -> page
  return select(pagectx(), "previous_page")
end

fn objects(page_value: page, role_name: string) -> selection<object>
  return select(page_value, "page_objects_by_role", role_name)
end

fn current_objects(role_name: string) -> selection<object>
  return objects(pagectx(), role_name)
end

fn children(base: object) -> selection<object>
  return select(base, "children")
end

fn descendants(base: object) -> selection<object>
  return select(base, "descendants")
end

fn document_pages() -> selection<page>
  return select(docctx(), "document_pages")
end

fn document_objects(role_name: string) -> selection<object>
  return select(docctx(), "document_objects_by_role", role_name)
end

fn all_objects(role_name: string) -> selection<object>
  return document_objects(role_name)
end

fn with_prop_all(items: selection<object>, key_name: string, value_name: string) -> selection<object>
  set_prop(items, key_name, value_name)
  return items
end

fn with_style_all(items: selection<object>, style_value: style) -> selection<object>
  set_style(items, style_value)
  return items
end
