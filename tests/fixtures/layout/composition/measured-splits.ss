import std:themes/default as *

const style: TextBlockStyle = default_theme().body with { layout.spacing_after = 32 }

page split_tables
text!(<<
あああああああああああ

あああああああああああ
>>, style)
let tables = place!(text(<<
| ああ | ああああああああ |
| ---{1fr} | ---{10fr} |
| ああ | ああああああああ |
>>, style) |=| text(<<
| ああ | ああああああああ |
| ---{1fr} | ---{10fr} |
| ああ | ああああああああ |
>>, style))
~ tables.left == page.left + 72
~ tables.right == page.right - 72
text!("Following component", style)
end
