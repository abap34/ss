fn h1(title_text: string) -> object
  let title_style = style("pop")
  let title = styled_text(title_text, "title", title_style)
  text_preset(title, "Helvetica-Bold", "36", "42", "1,0.3765,0.5098", "46", "72", "72")
  return title
end

fn h2(subtitle_text: string) -> object
  let subtitle = subtitle_object(subtitle_text)
  text_preset(subtitle, "Helvetica", "22", "30", "0.1569,0.1333,0.2196", "22", "78", "78")
  return subtitle
end

fn slide_title(title_text: string) -> object
  let chip_style = style("pop_chip")
  let title_style = style("pop")
  let chip = styled_text(title_text, "label", chip_style)
  let title = place_top_left(styled_text(title_text, "title", title_style), 72, 98)
  text_preset(chip, "Helvetica-Bold", "13", "18", "1,1,1", "0", "72", "72")
  chrome_paint(chip, "1,0.3765,0.5098", "1,0.6706,0.2941", "1.0", "10")
  text_preset(title, "Helvetica-Bold", "36", "42", "1,0.3765,0.5098", "46", "72", "72")
  place_same_top_right(chip, title, 72, 8)
  return title
end

fn slide_subtitle(subtitle_text: string) -> object
  let subtitle = place_top_span(subtitle_object(subtitle_text), 110, 110, 150)
  text_preset(subtitle, "Helvetica-Bold", "22", "30", "0.1569,0.1333,0.2196", "22", "78", "78")
  set_prop(subtitle, "text_cjk_bold_passes", "3")
  set_prop(subtitle, "text_cjk_bold_dx", "0.04")
  return subtitle
end

fn text(text_value: string) -> object
  return body_object(text_value)
end

fn lead(text_value: string) -> object
  return text(text_value)
end

fn math_text_block(text_value: string) -> object
  return framed_object(text_value, "math", "math_text", "108", "108", 14, 12, "1,0.9647,0.9294", "1,0.7373,0.3843", "1.4", "16")
end

fn math_block(text_value: string) -> object
  return math_text_block(text_value)
end

fn mathtex_block(text_value: string) -> object
  return framed_object(text_value, "math", "math_tex", "108", "108", 14, 12, "1,0.9647,0.9294", "1,0.7373,0.3843", "1.4", "16")
end

fn tex(text_value: string) -> object
  return mathtex_block(text_value)
end

fn figure_text_block(text_value: string) -> object
  return framed_object(text_value, "figure", "figure_text", "108", "108", 14, 12, "1,0.9647,0.9294", "1,0.7373,0.3843", "1.4", "16")
end

fn figure(text_value: string) -> object
  return figure_text_block(text_value)
end

fn image_figure(path_value: string, scale: number = 1) -> object
  return with_asset_scale(framed_object(path_value, "figure", "image_ref", "108", "108", 14, 12, "1,0.9647,0.9294", "1,0.7373,0.3843", "1.4", "16"), scale)
end

fn image(path_value: string, scale: number = 1) -> object
  let obj = image_figure(path_value, scale)
  require_asset_exists(obj)
  return obj
end

fn pdf_figure(path_value: string, scale: number = 1) -> object
  let obj = with_asset_scale(framed_object(path_value, "figure", "pdf_ref", "108", "108", 14, 12, "1,0.9647,0.9294", "1,0.7373,0.3843", "1.4", "16"), scale)
  require_asset_exists(obj)
  return obj
end

fn pdf(path_value: string, scale: number = 1) -> object
  return pdf_figure(path_value, scale)
end

fn code(text_value: string) -> object
  return framed_code_with_language(text_value, "python", "108", "108", 18, 14, "1,0.9647,0.9294", "1,0.7373,0.3843", "1.4", "16")
end

fn python_code(text_value: string) -> object
  return code(text_value)
end

fn code_block(text_value: string) -> object
  return framed_object(text_value, "code", "code", "108", "108", 18, 14, "1,0.9647,0.9294", "1,0.7373,0.3843", "1.4", "16")
end

fn plain_code(text_value: string) -> object
  return code_block(text_value)
end

fn note(text_value: string) -> object
  return inset_node(note_object(text_value), 124, 124)
end

fn callout(text_value: string) -> object
  return note(text_value)
end

fn quote(text_value: string) -> object
  return note(text_value)
end

fn toc_page(title_text: string) -> object
  slide_title(title_text)
  let list = toc_list_object()
  let chrome = panel(style("pop"))
  chrome_paint(chrome, "1,0.9647,0.9294", "1,0.7373,0.3843", "1.4", "16")
  surround(chrome, list, 14, 12)
  page_no()
  return list
end

fn title_page(title_text: string, subtitle_text: string, author_name: string) -> object
  let hero = style("pop_hero")
  let author_style = style("pop")
  let title = place_top_left(styled_text(title_text, "title", hero), 72, 152)
  let subtitle = styled_text(subtitle_text, "subtitle", hero)
  let author = styled_text(author_name, "byline", author_style)
  text_preset(title, "Helvetica-Bold", "52", "60", "0.4745,0.3765,1", "26", "72", "72")
  text_preset(subtitle, "Helvetica", "22", "30", "0.1569,0.1333,0.2196", "22", "78", "78")
  text_preset(author, "Helvetica-Bold", "18", "24", "1,0.6706,0.2941", "18", "72", "72")

  place_below_left(subtitle, title, 6, 28)
  place_same_top_right(author, title, 72, -4)
  return title
end
