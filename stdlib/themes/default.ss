import std:themes/base

fn h1(title_text: string) -> object
  let title = title_object(title_text)
  text_preset(title, "Helvetica", "34", "40", "0,0,0.0353", "54", "72", "72")
  return title
end

fn h2(subtitle_text: string) -> object
  let subtitle = subtitle_object(subtitle_text)
  text_preset(subtitle, "Helvetica", "18", "24", "0,0,0.0353", "34", "96", "96")
  return subtitle
end

fn slide_title(title_text: string) -> object
  let rule = rule("page_header")
  let label = label("page_section", title_text)
  let title = place_top_left(title_object(title_text), 72, 100)
  rule_paint(rule, "0.2745,0.5098,0.7059", "1.8", "1.5,3.0")
  text_paint(label, "Helvetica", "14", "18", "0.2745,0.5098,0.7059")
  underline_paint(label, "0.2745,0.5098,0.7059", "1.0", "-2.0")
  left_inset(rule, 72)
  right_inset(rule, 72)
  below(rule, title, 28)
  place_same_top_right(label, title, 72, 6)
  return title
end

fn slide_subtitle(subtitle_text: string) -> object
  let subtitle = place_top_span(subtitle_object(subtitle_text), 96, 96, 142)
  text_preset(subtitle, "Helvetica-Bold", "18", "24", "0,0,0.0353", "34", "96", "96")
  set_prop(subtitle, "text_cjk_bold_passes", "3")
  set_prop(subtitle, "text_cjk_bold_dx", "0.04")
  return subtitle
end

fn text(text_value: string) -> object
  return body_object(text_value)
end

fn tex(text_value: string, scale: number = 1) -> object
  let obj = framed_object(text_value, "math", "math_tex", "102", "102", 8, 8, "1,1,1", "0.9,0.92,0.96", "0.8", "10")
  set_prop(obj, "math_scale", str(scale))
  return obj
end

fn figure(text_value: string) -> object
  return flow_inset(figure_text_object(text_value), "102", "102")
end

fn image(path_value: string, scale: number = 1) -> object
  let obj = with_asset_scale(flow_inset(image_object(path_value), "102", "102"), scale)
  require_asset_exists(obj)
  return obj
end

fn pdf(path_value: string, scale: number = 1) -> object
  let obj = with_asset_scale(flow_inset(pdf_object(path_value), "102", "102"), scale)
  require_asset_exists(obj)
  return obj
end

fn code(text_value: string, language_name: string = "python") -> object
  return framed_code_with_language(text_value, language_name, "102", "102", 12, 10, "0.9725,0.9843,1", "0.82,0.84,0.88", "1.0", "10")
end

fn note(text_value: string) -> object
  return flow_inset(note_object(text_value), "120", "120")
end

fn toc_page(title_text: string) -> object
  slide_title(title_text)
  let list = toc_list_object()
  let chrome = panel(style("toc"))
  chrome_paint(chrome, "0.9412,0.9725,1", "0.82,0.84,0.88", "1.0", "12")
  surround(chrome, list, 10, 8)
  page_no()
  return list
end

fn title_page(title_text: string, subtitle_text: string, author_name: string) -> object
  let hero = style("hero")
  let title = place_top_left(styled_text(title_text, "title", hero), 72, 150)
  let subtitle = styled_text(subtitle_text, "subtitle", hero)
  let author = byline_object(author_name)
  text_preset(title, "Helvetica", "50", "58", "0.2745,0.5098,0.7059", "24", "72", "72")
  text_preset(subtitle, "Helvetica", "20", "26", "0,0,0.0353", "22", "72", "72")
  text_preset(author, "Helvetica", "20", "26", "0.2745,0.5098,0.7059", "18", "72", "72")

  place_below_left(subtitle, title, 0, 24)
  place_same_top_right(author, title, 72, -6)
  return title
end
