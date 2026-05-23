import std:themes/base

fn h1(title_text: string) -> object
  let title = title_obj(title_text)
  txt(title, "Helvetica", "34", "40", "0,0,0.0353", "54", "72", "72")
  return title
end

fn h2(subtitle_text: string) -> object
  let subtitle = sub_obj(subtitle_text)
  txt(subtitle, "Helvetica", "18", "24", "0,0,0.0353", "34", "96", "96")
  return subtitle
end

fn head(title_text: string) -> object
  let rule = rule("page_header")
  let label = label("page_section", title_text)
  let title = tl(title_obj(title_text), 72, 100)
  rule_l(rule, "0.2745,0.5098,0.7059", "1.8", "1.5,3.0")
  txt_p(label, "Helvetica", "14", "18", "0.2745,0.5098,0.7059")
  under(label, "0.2745,0.5098,0.7059", "1.0", "-2.0")
  pin_l(rule, 72)
  pin_r(rule, 72)
  below(rule, title, 28)
  same_tr(label, title, 72, 6)
  return title
end

fn subhead(subtitle_text: string) -> object
  let subtitle = tspan(sub_obj(subtitle_text), 96, 96, 142)
  txt(subtitle, "Helvetica-Bold", "18", "24", "0,0,0.0353", "34", "96", "96")
  set_prop(subtitle, "text_cjk_bold_passes", "3")
  set_prop(subtitle, "text_cjk_bold_dx", "0.04")
  return subtitle
end

fn tex(text_value: string, scale: number = 1) -> object
  let obj = frame(text_value, "math", "math_tex", "102", "102", 8, 8, "1,1,1", "0.9,0.92,0.96", "0.8", "10")
  set_prop(obj, "render_kind", "vector_math")
  set_prop(obj, "text_parse", "none")
  set_prop(obj, "math_scale", str(scale))
  return obj
end

fn code(text_value: string, language_name: string = "python") -> object
  return code_box(text_value, language_name, "102", "102", 12, 10, "0.9725,0.9843,1", "0.82,0.84,0.88", "1.0", "10")
end

fn toc(title_text: string) -> object
  head(title_text)
  let list = toc_obj()
  let chrome = panel(style("toc"))
  box(chrome, "0.9412,0.9725,1", "0.82,0.84,0.88", "1.0", "12")
  surround(chrome, list, 10, 8)
  pageno()
  return list
end

fn cover(title_text: string, subtitle_text: string, author_name: string) -> object
  let hero = style("hero")
  let title = tl(styled(title_text, "title", hero), 72, 150)
  let subtitle = styled(subtitle_text, "subtitle", hero)
  let author = by_obj(author_name)
  txt(title, "Helvetica", "50", "58", "0.2745,0.5098,0.7059", "24", "72", "72")
  txt(subtitle, "Helvetica", "20", "26", "0,0,0.0353", "22", "72", "72")
  txt(author, "Helvetica", "20", "26", "0.2745,0.5098,0.7059", "18", "72", "72")

  below_l(subtitle, title, 0, 24)
  same_tr(author, title, 72, -6)
  return title
end
