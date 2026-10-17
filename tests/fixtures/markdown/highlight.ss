import std:themes/default as *

page highlight
text! <<
# An ==important heading==

An ==important **detail**== with ==*italic text*, `code`, and [a link](https://example.com)==.

- ==Highlighted list item==
- Literal code: `==not highlighted==`

> A ==highlighted quotation==.

| Topic | Description |
| ---{100pt} | ---{1fr} |
| ==Note== | ==Highlighted table content wraps within its allocated column width.== |
>>
let note = text!("A ==custom green highlight==")
note.text.markdown.highlight_fill = c"#b9f6ca"
end

page wrapping
let body = text!("Before ==a highlighted passage that wraps across several lines and includes **bold text** and ![star](fa:star) an icon== after.")
~ body.width == 360
end
