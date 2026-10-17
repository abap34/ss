import std:templates/slide/style as { HeadStyle, RuleBlockStyle, MarkedCalloutStyle }
import std:theme as theme
import std:internal/style as styles
import std:internal/callout as helpers
import std:internal/objects as objects
import std:layout as layout
import std:components/callout as callouts

fn/! head(title_text: String, style: HeadStyle = theme::current_theme().head) -> Object
  let rule = styles::rule_object(style.rule)
  let title = styles::text_object(title_text, "title", style.title)
  ~ title.left == page.left + style.title.layout.x
  ~ title.top == page.top - style.top
  ~ rule.left == title.left
  ~ rule.right == page.right - style.title.layout.right_inset
  ~ rule.top == title.bottom - style.gap
  return group(title, rule)
end

type Cols {
  left: Number = 96
  right: Number = 96
  top: Number? = none
  gap: Number = 36
  ratio: Number = 0.5
  page_width: Number = 1280
}

type Cols2 {
  root: Object
  left: Object
  right: Object
}

fn cols2_parts(left: Object, right: Object, spec: Cols = Cols {}) -> Cols2
  let root = group(left, right)

  ~ left.left == page.left + spec.left
  ~ left.width == (spec.page_width - spec.left - spec.right - spec.gap) * spec.ratio
  ~ right.left == left.right + spec.gap
  ~ right.right == page.right - spec.right
  ~ right.top == left.top
  ~ root.left == left.left
  ~ root.top == left.top

  if spec.top?
    let top = spec.top ?? 0
    ~ left.top == page.top - top
  end

  return Cols2 {
    root = root
    left = left
    right = right
  }
end

fn cols2(left: Object, right: Object, spec: Cols = Cols {}) -> Object
  return cols2_parts(left, right, spec).root
end

fn/! annotate(source_text: String, target_text: String, note_text: String, style: MarkedCalloutStyle = theme::current_theme().callout) -> Object
  if !str_contains(source_text, target_text)
    report_warning("MarkedCalloutTargetMissing: target text was not found in source text")
  end

  let before = helpers::marked_callout_text(str_before(source_text, target_text), style.text)
  let target = helpers::marked_callout_text(target_text, style.target)
  let after = helpers::marked_callout_text(str_after(source_text, target_text), style.text)

  let target_back = objects::panel_obj()
  target_back.chrome = style.target_chrome
  layout::surround(target_back, target, style.target_chrome.pad_x, style.target_chrome.pad_y)

  ~ before.left == page.left + style.x
  ~ before.top == page.top - style.top_y
  ~ target.left == before.right + style.target_chrome.pad_x
  ~ target.top == before.top
  ~ after.left == target.right + style.target_chrome.pad_x
  ~ after.top == before.top

  let callout = callouts::callout_parts(target, note_text, style.callout)
  ~ callout.note.left == page.left + style.callout_x
  ~ callout.note.top == page.top - style.callout_top_y
  ~ callout.note.width == style.callout_width
  return group(target_back, before, target, after, callout.root)
end
