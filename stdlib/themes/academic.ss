import std:themes/base

fn h1(text_value: string) -> object
  let content = title_object(text_value)
  text_preset(content, "Helvetica", "32", "36", "0,0,0.0353", "48", "96", "96")
  return content
end

fn h2(text_value: string) -> object
  let content = subtitle_object(text_value)
  text_preset(content, "Helvetica-Bold", "28", "30", "0,0,0.0353", "42", "96", "96")
  return content
end

fn h3(text_value: string) -> object
  let content = subtitle_object(text_value)
  text_preset(content, "Helvetica-Bold", "24", "28", "0,0,0.0353", "36", "96", "96")
  return content
end

fn slide_title(title_text: string) -> object
  let title = place_top_left(title_object(title_text), 30, 30)
  text_preset(title, "Helvetica-Bold", "34", "50", "0,0,0.0353", "35", "72", "72")
  return title
end

fn slide_subtitle(subtitle_text: string) -> object
  let subtitle = place_top_span(subtitle_object(subtitle_text), 96, 96, 150)
  text_preset(subtitle, "Helvetica-Bold", "12", "24", "0,0,0.0353", "34", "96", "96")
  return subtitle
end

fn text(text_value: string) -> object
  let body = body_object(text_value)
  markdown_code_paint(body, "18", "24", "12", "10", "0.94,0.94,0.94", "0.78,0.78,0.78", "1.0", "0")
  return body
end

fn tex(text_value: string, scale: number = 1) -> object
  let obj = flow_inset(math_tex_object(text_value), "102", "102")
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
  return framed_code_with_language(text_value, language_name, "102", "102", 12, 10, "0.94,0.94,0.94", "0.78,0.78,0.78", "1.0", "0")
end

fn note(text_value: string) -> object
  return flow_inset(note_object(text_value), "120", "120")
end

fn toc_page(title_text: string) -> object
  slide_title(title_text)
  let toc = toc_list_object()
  page_no()
  return toc
end

fn title_page(title_text: string, subtitle_text: string, author_name: string, date: string) -> object
  let title = place_top_left(title_object(title_text), 72, 240)
  let subtitle = subtitle_object(subtitle_text)
  let author = byline_object(author_name)
  let date_text = byline_object(date)
  text_preset(title, "Helvetica", "44", "40", "0,0,0.0353", "54", "72", "72")
  text_preset(subtitle, "Helvetica-Bold", "18", "24", "0,0,0.0353", "34", "96", "96")
  text_preset(author, "Helvetica", "20", "26", "0,0,0.0353", "18", "72", "72")
  text_preset(date_text, "Helvetica", "14", "20", "0,0,0.0353", "18", "72", "72")

  place_below_left(subtitle, title, 0, 28)
  place_below_left(author, subtitle, 0, 36)
  place_below_left(date_text, author, 0, 18)
  return title
end
