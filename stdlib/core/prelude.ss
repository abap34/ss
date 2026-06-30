import std:core/classes as classes
import std:core/layout as layout
import std:core/objects as objects
import std:core/render as render
import std:core/selectors as selectors
import std:core/utils as utils
import std:core/generated as generated
import std:core/components as components

fn vflow(policy: LayoutPolicy, center_offset: Number = 0) -> Void
  layout::vflow(policy, center_offset)
end

fn vflow_doc(policy: LayoutPolicy, center_offset: Number = 0) -> Void
  layout::vflow_doc(policy, center_offset)
end

fn cols2_parts(left: Object, right: Object, spec: Cols = Cols {}) -> Cols2
  return layout::cols2_parts(left, right, spec)
end

fn cols2(left: Object, right: Object, spec: Cols = Cols {}) -> Object
  return layout::cols2(left, right, spec)
end

fn surround(panel: Object, inner: Object, pad_x: Number, pad_y: Number) -> Void
  layout::surround(panel, inner, pad_x, pad_y)
end

fn/! obj(text_value: String, role_name: String, payload_name: String) -> Object
  return objects::obj(text_value, role_name, payload_name)
end

fn place!(obj: Object) -> Object
  return objects::place!(obj)
end

fn/! txt_obj(text_value: String, role_name: String) -> Object
  return objects::txt_obj(text_value, role_name)
end

fn/! title_obj(text_value: String) -> Object
  return objects::title_obj(text_value)
end

fn/! sub_obj(text_value: String) -> Object
  return objects::sub_obj(text_value)
end

fn/! body_obj(text_value: String) -> Object
  return objects::body_obj(text_value)
end

fn/! note_obj(text_value: String) -> Object
  return objects::note_obj(text_value)
end

fn/! by_obj(text_value: String) -> Object
  return objects::by_obj(text_value)
end

fn/! lab_obj(text_value: String) -> Object
  return objects::lab_obj(text_value)
end

fn/! cite_obj(text_value: String) -> Object
  return objects::cite_obj(text_value)
end

fn/! rule_obj() -> Object
  return objects::rule_obj()
end

fn/! shape_obj() -> Object
  return objects::shape_obj()
end

fn/! panel_obj() -> Object
  return objects::panel_obj()
end

fn spacer(height: Number, width: Number = 1) -> Object
  return objects::spacer(height, width)
end

fn vspace(height: Number) -> Object
  return objects::vspace(height)
end

fn/! raw_obj(text_value: String, role_name: String, payload_name: String) -> Object
  return objects::raw_obj(text_value, role_name, payload_name)
end

fn/! math_obj(text_value: String) -> Object
  return objects::math_obj(text_value)
end

fn/! tex_obj(text_value: String) -> Object
  return objects::tex_obj(text_value)
end

fn/! fig_obj(text_value: String) -> Object
  return objects::fig_obj(text_value)
end

fn/! img_obj(path_value: String) -> Object
  return objects::img_obj(path_value)
end

fn/! pdf_obj(path_value: String) -> Object
  return objects::pdf_obj(path_value)
end

fn/! code_obj(text_value: String) -> Object
  return objects::code_obj(text_value)
end

fn tex_preamble(src: String) -> Void
  render::tex_preamble(src)
end

fn page_tex_preamble(src: String) -> Void
  render::page_tex_preamble(src)
end

fn tex_preamble_file(path: String) -> Void
  render::tex_preamble_file(path)
end

fn page_tex_preamble_file(path: String) -> Void
  render::page_tex_preamble_file(path)
end

fn link(obj: Object, id: String) -> Object
  return render::link(obj, id)
end

fn md_link(label: String, href: String) -> String
  return render::md_link(label, href)
end

fn scale(obj: Object, factor: Number) -> Object
  return render::scale(obj, factor)
end

fn md_code(obj: Object, font_size_name: Number, line_height_name: Number, pad_x_name: Number, pad_y_name: Number, fill_name: Color?, stroke_name: Color?, line_width_name: Number, radius_name: Number) -> Object
  return render::md_code(obj, font_size_name, line_height_name, pad_x_name, pad_y_name, fill_name, stroke_name, line_width_name, radius_name)
end

fn code_theme_github_light() -> CodeHighlightTheme
  return render::code_theme_github_light()
end

fn code_theme_github_dark() -> CodeHighlightTheme
  return render::code_theme_github_dark()
end

fn code_theme_solarized_light() -> CodeHighlightTheme
  return render::code_theme_solarized_light()
end

fn code_theme_solarized_dark() -> CodeHighlightTheme
  return render::code_theme_solarized_dark()
end

fn code_theme_one_dark() -> CodeHighlightTheme
  return render::code_theme_one_dark()
end

fn code_theme_monokai() -> CodeHighlightTheme
  return render::code_theme_monokai()
end

fn code_theme(obj: Object, theme: CodeHighlightTheme) -> Object
  return render::code_theme(obj, theme)
end

fn code_theme_all(theme: CodeHighlightTheme) -> Void
  render::code_theme_all(theme)
end

fn code_theme_page(theme: CodeHighlightTheme) -> Void
  render::code_theme_page(theme)
end

fn md_bold(obj: Object, color_name: Color?) -> Object
  return render::md_bold(obj, color_name)
end

fn md_table(obj: Object, pad_x_name: Number, pad_y_name: Number, border_name: Color, line_width_name: Number, header_fill_name: Color, alt_row_fill_name: Color? = none) -> Object
  return render::md_table(obj, pad_x_name, pad_y_name, border_name, line_width_name, header_fill_name, alt_row_fill_name)
end

fn box(obj: Object, fill_name: Color?, stroke_name: Color?, line_width_name: Number, radius_name: Number) -> Object
  return render::box(obj, fill_name, stroke_name, line_width_name, radius_name)
end

fn under(obj: Object, color_name: Color?, line_width_name: Number, offset_name: Number) -> Object
  return render::under(obj, color_name, line_width_name, offset_name)
end

fn rule_l(obj: Object, stroke_name: Color?, line_width_name: Number, dash_name: String) -> Object
  return render::rule_l(obj, stroke_name, line_width_name, dash_name)
end

fn fit(obj: Object, policy_name: FitPolicy) -> Object
  return render::fit(obj, policy_name)
end

fn fit_warn(obj: Object) -> Object
  return render::fit_warn(obj)
end

fn fit_error(obj: Object) -> Object
  return render::fit_error(obj)
end

fn fit_ignore(obj: Object) -> Object
  return render::fit_ignore(obj)
end

fn prev_page() -> Page
  return selectors::prev_page()
end

fn objs(page_value: Page, role_name: String) -> Selection<Object>
  return selectors::objs(page_value, role_name)
end

fn objs_here(role_name: String) -> Selection<Object>
  return selectors::objs_here(role_name)
end

fn children(base: Object) -> Selection<Object>
  return selectors::children(base)
end

fn desc(base: Object) -> Selection<Object>
  return selectors::desc(base)
end

fn doc_pages() -> Selection<Page>
  return selectors::doc_pages()
end

fn pages(doc: Document) -> Selection<Page>
  return selectors::pages(doc)
end

fn objs_all(role_name: String) -> Selection<Object>
  return selectors::objs_all(role_name)
end

fn doc_objs(doc: Document, role_name: String) -> Selection<Object>
  return selectors::doc_objs(doc, role_name)
end

fn page_of(obj: Object) -> Page
  return selectors::page_of(obj)
end

fn union(left: Selection<Object>, right: Selection<Object>) -> Selection<Object>
  return selectors::union(left, right)
end

fn intersect(left: Selection<Object>, right: Selection<Object>) -> Selection<Object>
  return selectors::intersect(left, right)
end

fn diff(left: Selection<Object>, right: Selection<Object>) -> Selection<Object>
  return selectors::diff(left, right)
end

fn math_align(obj: Object, align_name: Align) -> Object
  return utils::math_align(obj, align_name)
end

fn left_math(obj: Object) -> Object
  return utils::left_math(obj)
end

fn center_math(obj: Object) -> Object
  return utils::center_math(obj)
end

fn right_math(obj: Object) -> Object
  return utils::right_math(obj)
end

fn math_align_all(align_name: Align) -> Void
  utils::math_align_all(align_name)
end

fn left_math_all() -> Void
  utils::left_math_all()
end

fn center_math_all() -> Void
  utils::center_math_all()
end

fn right_math_all() -> Void
  utils::right_math_all()
end

fn math_align_objects(items: Selection<Object>, align_name: Align) -> Selection<Object>
  return utils::math_align_objects(items, align_name)
end

fn pageno_s(page_no: Object) -> Object
  return generated::pageno_s(page_no)
end

fn/! pageno_obj() -> Object
  return generated::pageno_obj()
end

fn pagenos!(format: String? = none) -> Void
  generated::pagenos!(format)
end

fn footers!(text_value: String) -> Void
  generated::footers!(text_value)
end

fn logos!(path_value: String, scale: Number = 1) -> Void
  generated::logos!(path_value, scale)
end

fn watermark!(text_value: String) -> Void
  generated::watermark!(text_value)
end

fn need_titles() -> Void
  generated::need_titles()
end

fn numbered_item_role(counter_name: String) -> String
  return generated::numbered_item_role(counter_name)
end

fn/! numbered_item(counter_name: String, text_value: String) -> Object
  return generated::numbered_item(counter_name, text_value)
end

fn numbered_item_repr(item: Object) -> String
  return generated::numbered_item_repr(item)
end

fn set_numbered_item(item: Object, index: Number, format: String) -> Object
  return generated::set_numbered_item(item, index, format)
end

fn numbering!(counter_name: String, format: String = "{number}. {text}") -> Void
  generated::numbering!(counter_name, format)
end

fn mk_pagenos!(doc: Document, format: String?) -> Void
  generated::mk_pagenos!(doc, format)
end

fn mk_pageno!(page_value: Page, doc: Document, format: String?) -> Page
  return generated::mk_pageno!(page_value, doc, format)
end

fn set_pagenos(doc: Document) -> Void
  generated::set_pagenos(doc)
end

fn set_pageno(page_no: Object, doc: Document, format: String?) -> Object
  return generated::set_pageno(page_no, doc, format)
end

fn pageno_repr(page_no: Object) -> String
  return generated::pageno_repr(page_no)
end

fn mk_footers!(doc: Document, text_value: String) -> Void
  generated::mk_footers!(doc, text_value)
end

fn mk_footer!(page_value: Page, text_value: String) -> Page
  return generated::mk_footer!(page_value, text_value)
end

fn mk_logos!(doc: Document, path_value: String, scale: Number) -> Void
  generated::mk_logos!(doc, path_value, scale)
end

fn mk_logo!(page_value: Page, path_value: String, scale: Number) -> Page
  return generated::mk_logo!(page_value, path_value, scale)
end

fn mk_marks!(doc: Document, text_value: String) -> Void
  generated::mk_marks!(doc, text_value)
end

fn mk_mark!(page_value: Page, text_value: String) -> Page
  return generated::mk_mark!(page_value, text_value)
end

fn toc_obj() -> Object
  return generated::toc_obj()
end

fn set_tocs(doc: Document) -> Void
  generated::set_tocs(doc)
end

fn toc_row(title: Object, page_value: Page) -> String
  return generated::toc_row(title, page_value)
end

fn toc_text(doc: Document) -> String
  return generated::toc_text(doc)
end

fn set_toc(toc: Object, doc: Document) -> Object
  return generated::set_toc(toc, doc)
end

fn toc_repr(toc: Object) -> String
  return generated::toc_repr(toc)
end

fn chk_titles(doc: Document) -> Void
  generated::chk_titles(doc)
end

fn warn_title(page_value: Page) -> Page
  return generated::warn_title(page_value)
end

fn/! title(text_value: String) -> Object
  return components::title(text_value)
end

fn/! subtitle(text_value: String) -> Object
  return components::subtitle(text_value)
end

fn/! math(text_value: String, scale: Number = 1) -> Object
  return components::math(text_value, scale)
end

fn/! mathtex(text_value: String) -> Object
  return components::mathtex(text_value)
end

fn/! panel() -> Object
  return components::panel()
end

fn/! byline(text_value: String) -> Object
  return components::byline(text_value)
end

fn/! label(text_value: String) -> Object
  return components::label(text_value)
end

fn/! rule() -> Object
  return components::rule()
end

fn/! line() -> Object
  return components::line()
end

fn line_s(obj: Object, style: LineStyle) -> Object
  return components::line_s(obj, style)
end

fn/! line_up(from: Object, to: Object, style: LineStyle = LineStyle {}) -> Object
  return components::line_up(from, to, style)
end

fn/! line_down(from: Object, to: Object, style: LineStyle = LineStyle {}) -> Object
  return components::line_down(from, to, style)
end

fn/! arrow_up(from: Object, to: Object, style: LineStyle = LineStyle {}) -> Object
  return components::arrow_up(from, to, style)
end

fn/! arrow_down(from: Object, to: Object, style: LineStyle = LineStyle {}) -> Object
  return components::arrow_down(from, to, style)
end

fn/! callout_text(text_value: String, style: CalloutStyle) -> Object
  return components::callout_text(text_value, style)
end

fn/! callout_bar(color_name: Color?, thickness: Number) -> Object
  return components::callout_bar(color_name, thickness)
end

fn/! callout_hbar(color_name: Color?, thickness: Number) -> Object
  return components::callout_hbar(color_name, thickness)
end

fn/! callout_vbar(color_name: Color?, thickness: Number) -> Object
  return components::callout_vbar(color_name, thickness)
end

fn/! callout_left_bracket(inner: Object, style: CalloutStyle) -> Object
  return components::callout_left_bracket(inner, style)
end

fn/! bracket_callout(target: Object, text_value: String, x: Number, top_y: Number, width: Number, style: CalloutStyle = CalloutStyle {}) -> Object
  return components::bracket_callout(target, text_value, x, top_y, width, style)
end

fn/! marked_callout_text(text_value: String, color_name: Color, weight: Number, size: Number, line_height: Number) -> Object
  return components::marked_callout_text(text_value, color_name, weight, size, line_height)
end

fn marked_callout!(source_text: String, target_text: String, note_text: String, style: MarkedCalloutStyle = MarkedCalloutStyle {}) -> Object
  return components::marked_callout!(source_text, target_text, note_text, style)
end

fn annotate!(source_text: String, target_text: String, note_text: String, style: MarkedCalloutStyle = MarkedCalloutStyle {}) -> Object
  return components::annotate!(source_text, target_text, note_text, style)
end

fn annotate_down!(source_text: String, target_text: String, note_text: String, style: MarkedCalloutStyle = MarkedCalloutStyle {}) -> Object
  return components::annotate_down!(source_text, target_text, note_text, style)
end

fn page_bg(fill_name: Color?) -> Void
  components::page_bg(fill_name)
end

fn doc_bg(fill_name: Color?) -> Void
  components::doc_bg(fill_name)
end

fn/! frame_s(inner: Object, pad_x: Number, pad_y: Number) -> Object
  return components::frame_s(inner, pad_x, pad_y)
end

fn/! frame(text_value: String, role_name: String, payload_name: String, left: Number, right: Number, pad_x: Number, pad_y: Number, fill_name: Color?, stroke_name: Color?, line_width_name: Number, radius_name: Number) -> Object
  return components::frame(text_value, role_name, payload_name, left, right, pad_x, pad_y, fill_name, stroke_name, line_width_name, radius_name)
end

fn surround_s(inner: Object, pad_x: Number, pad_y: Number) -> Object
  return components::surround_s(inner, pad_x, pad_y)
end

fn border_p(inner: Object, pad_x: Number, pad_y: Number, fill_name: Color?, stroke_name: Color?, line_width: Number, radius: Number) -> Object
  return components::border_p(inner, pad_x, pad_y, fill_name, stroke_name, line_width, radius)
end

fn border(inner: Object, pad_x: Number = 12, pad_y: Number = 8, stroke_name: Color? = c"0.36,0.40,0.48", line_width: Number = 1, radius: Number = 8) -> Object
  return components::border(inner, pad_x, pad_y, stroke_name, line_width, radius)
end

fn outline(inner: Object, stroke_name: Color? = c"0.36,0.40,0.48", line_width: Number = 1, radius: Number = 8) -> Object
  return components::outline(inner, stroke_name, line_width, radius)
end

fn/! code_l(text_value: String, language_name: String) -> Object
  return components::code_l(text_value, language_name)
end

fn code_in(text_value: String, language_name: String, left: Number, right: Number) -> Object
  return components::code_in(text_value, language_name, left, right)
end

fn code_panel(text_value: String, language_name: String, left: Number, right: Number, pad_x: Number, pad_y: Number) -> Object
  return components::code_panel(text_value, language_name, left, right, pad_x, pad_y)
end

fn code_box(text_value: String, language_name: String, left: Number, right: Number, pad_x: Number, pad_y: Number, fill_name: Color?, stroke_name: Color?, line_width_name: Number, radius_name: Number) -> Object
  return components::code_box(text_value, language_name, left, right, pad_x, pad_y, fill_name, stroke_name, line_width_name, radius_name)
end

fn/! text(text_value: String) -> Object
  return components::text(text_value)
end

fn/! tex(text_value: String, scale: Number = 1) -> Object
  return components::tex(text_value, scale)
end

fn/! figure(text_value: String) -> Object
  return components::figure(text_value)
end

fn/! image(path_value: String, factor: Number = 1) -> Object
  return components::image(path_value, factor)
end

fn/! pdf(path_value: String, factor: Number = 1) -> Object
  return components::pdf(path_value, factor)
end

fn/! code(text_value: String, language_name: String = "python") -> Object
  return components::code(text_value, language_name)
end

fn/! code_file(path_value: String, language_name: String = "plain") -> Object
  return components::code_file(path_value, language_name)
end

fn/! note(text_value: String) -> Object
  return components::note(text_value)
end

fn/! citation(target: Object, number: Number, reference_text: String) -> Object
  return components::citation(target, number, reference_text)
end

fn/! pageno() -> Object
  return components::pageno()
end
