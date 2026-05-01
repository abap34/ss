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

fn lead(text_value: string) -> object
  return text(text_value)
end

fn math_text_block(text_value: string) -> object
  return flow_inset(math_text_object(text_value), "102", "102")
end

fn math_block(text_value: string) -> object
  return math_text_block(text_value)
end

fn mathtex_block(text_value: string) -> object
  return flow_inset(math_tex_object(text_value), "102", "102")
end

fn tex(text_value: string) -> object
  return mathtex_block(text_value)
end

fn figure_text_block(text_value: string) -> object
  return flow_inset(figure_text_object(text_value), "102", "102")
end

fn figure(text_value: string) -> object
  return figure_text_block(text_value)
end

fn image_figure(path_value: string) -> object
  return flow_inset(image_object(path_value), "102", "102")
end

fn image(path_value: string) -> object
  let obj = image_figure(path_value)
  require_asset_exists(obj)
  return obj
end

fn pdf_figure(path_value: string, scale: number = 1) -> object
  return with_asset_scale(flow_inset(pdf_object(path_value), "102", "102"), scale)
end

fn pdf(path_value: string, scale: number = 1) -> object
  return pdf_figure(path_value, scale)
end

fn code(text_value: string) -> object
  return framed_code_with_language(text_value, "python", "102", "102", 12, 10, "0.94,0.94,0.94", "0.78,0.78,0.78", "1.0", "0")
end

fn python_code(text_value: string) -> object
  return code(text_value)
end

fn code_block(text_value: string) -> object
  return framed_object(text_value, "code", "code", "102", "102", 12, 10, "0.94,0.94,0.94", "0.78,0.78,0.78", "1.0", "0")
end

fn plain_code(text_value: string) -> object
  return code_block(text_value)
end

fn note(text_value: string) -> object
  return flow_inset(note_object(text_value), "120", "120")
end

fn callout(text_value: string) -> object
  return note(text_value)
end

fn quote(text_value: string) -> object
  return note(text_value)
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
