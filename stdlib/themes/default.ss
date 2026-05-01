fn h1(title_text)
  let title = title_object(title_text)
  text_preset(title, "Helvetica", "34", "40", "0,0,0.0353", "54", "72", "72")
  return title
end

fn h2(subtitle_text)
  let subtitle = subtitle_object(subtitle_text)
  text_preset(subtitle, "Helvetica", "18", "24", "0,0,0.0353", "34", "96", "96")
  return subtitle
end

fn slide_title(title_text)
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

fn slide_subtitle(subtitle_text)
  let subtitle = place_top_span(subtitle_object(subtitle_text), 96, 96, 142)
  text_preset(subtitle, "Helvetica-Bold", "18", "24", "0,0,0.0353", "34", "96", "96")
  set_prop(subtitle, "text_cjk_bold_passes", "3")
  set_prop(subtitle, "text_cjk_bold_dx", "0.04")
  return subtitle
end

fn text(text_value)
  return body_object(text_value)
end

fn lead(text_value)
  return text(text_value)
end

fn math_text_block(text_value)
  return framed_object(text_value, "math", "math_text", "102", "102", 8, 8, "1,1,1", "0.9,0.92,0.96", "0.8", "10")
end

fn math_block(text_value)
  return math_text_block(text_value)
end

fn mathtex_block(text_value)
  return framed_object(text_value, "math", "math_tex", "102", "102", 8, 8, "1,1,1", "0.9,0.92,0.96", "0.8", "10")
end

fn tex(text_value)
  return mathtex_block(text_value)
end

fn figure_text_block(text_value)
  return flow_inset(figure_text_object(text_value), "102", "102")
end

fn figure(text_value)
  return figure_text_block(text_value)
end

fn image_figure(path_value)
  return flow_inset(image_object(path_value), "102", "102")
end

fn image(path_value)
  return image_figure(path_value)
end

fn pdf_figure(path_value)
  return flow_inset(pdf_object(path_value), "102", "102")
end

fn pdf(path_value)
  return pdf_figure(path_value)
end

fn code(text_value)
  return framed_code_with_language(text_value, "python", "102", "102", 12, 10, "0.9725,0.9843,1", "0.82,0.84,0.88", "1.0", "10")
end

fn python_code(text_value)
  return code(text_value)
end

fn code_block(text_value)
  return framed_object(text_value, "code", "code", "102", "102", 12, 10, "0.9725,0.9843,1", "0.82,0.84,0.88", "1.0", "10")
end

fn plain_code(text_value)
  return code_block(text_value)
end

fn note(text_value)
  return flow_inset(note_object(text_value), "120", "120")
end

fn callout(text_value)
  return note(text_value)
end

fn quote(text_value)
  return note(text_value)
end

fn toc_page(title_text)
  slide_title(title_text)
  let list = toc_list_object()
  let chrome = panel(style("toc"))
  chrome_paint(chrome, "0.9412,0.9725,1", "0.82,0.84,0.88", "1.0", "12")
  surround(chrome, list, 10, 8)
  page_no()
  return list
end

fn title_page(title_text, subtitle_text, author_name)
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
