import std:themes/default as *

page ok
  figure!(text("## Figure heading", current_theme() with { h2.text.size = 38 }), "Caption")
end
