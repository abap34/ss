import std:components/callout/style as { CalloutStyle }
import std:theme as theme
import std:internal/callout as helpers
import std:graphics/connectors as connectors
import std:components/box as boxes

type CalloutParts {
  root: Object
  note: Object
  background: Object
  connector: Object
}

fn callout_parts(target: Object, content: String, style: CalloutStyle = theme::current_theme().callout.callout) -> CalloutParts
  let note = helpers::callout_text(content, style)
  let framed = boxes::box_parts(note, style.chrome)
  if style.left_bracket
    let bracket = helpers::callout_left_bracket(framed.background, style)
    let connector = connectors::connect(target, bracket, helpers::callout_connector_style(style))
    return CalloutParts { root = group(framed.root, bracket, connector) note = note background = framed.background connector = connector }
  else
    let connector = connectors::connect(target, framed.background, helpers::callout_connector_style(style))
    return CalloutParts { root = group(framed.root, connector) note = note background = framed.background connector = connector }
  end
end

fn/! callout(target: Object, content: String, style: CalloutStyle = theme::current_theme().callout.callout) -> Object
  return callout_parts(target, content, style).root
end
