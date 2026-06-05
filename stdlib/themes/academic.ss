import std:themes/base

fn h1(text_value: String) -> Object
  let content = title_obj(text_value)
  txt(content, "Helvetica", 32, 36, c"0,0,0.0353", 48, 96, 96)
  return content
end

fn h2(text_value: String) -> Object
  let content = sub_obj(text_value)
  txt(content, "Helvetica-Bold", 28, 30, c"0,0,0.0353", 42, 96, 96)
  return content
end

fn h3(text_value: String) -> Object
  let content = sub_obj(text_value)
  txt(content, "Helvetica-Bold", 24, 28, c"0,0,0.0353", 36, 96, 96)
  return content
end

fn head(title_text: String) -> Object
  let title = tl(title_obj(title_text), 30, 30)
  txt(title, "Helvetica-Bold", 34, 50, c"0,0,0.0353", 35, 72, 72)
  return title
end

fn subhead(subtitle_text: String) -> Object
  let subtitle = tspan(sub_obj(subtitle_text), 96, 96, 150)
  txt(subtitle, "Helvetica-Bold", 12, 24, c"0,0,0.0353", 34, 96, 96)
  return subtitle
end

fn text(text_value: String) -> Object
  let body = body_obj(text_value)
  md_code(body, 18, 24, 12, 10, c"0.94,0.94,0.94", c"0.78,0.78,0.78", 1.0, 0)
  return body
end

fn code(text_value: String, language_name: String = "python") -> Object
  return code_box(text_value, language_name, 102, 102, 12, 10, c"0.94,0.94,0.94", c"0.78,0.78,0.78", 1.0, 0)
end

fn toc(title_text: String) -> Object
  head(title_text)
  let toc = toc_obj()
  pageno()
  return toc
end

fn cover(title_text: String, subtitle_text: String, author_name: String, date: String = "") -> Object
  let title = tl(title_obj(title_text), 72, 240)
  let subtitle = sub_obj(subtitle_text)
  let author = by_obj(author_name)
  let date_text = by_obj(date)
  txt(title, "Helvetica", 44, 40, c"0,0,0.0353", 54, 72, 72)
  txt(subtitle, "Helvetica-Bold", 18, 24, c"0,0,0.0353", 34, 96, 96)
  txt(author, "Helvetica", 20, 26, c"0,0,0.0353", 18, 72, 72)
  txt(date_text, "Helvetica", 14, 20, c"0,0,0.0353", 18, 72, 72)

  below_l(subtitle, title, 0, 28)
  below_l(author, subtitle, 0, 36)
  below_l(date_text, author, 0, 18)
  return title
end
