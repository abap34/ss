import std:themes/default as *

page semantic_content
let body = text! <<
SelectableTextToken [link](https://example.com/semantic)

1. one
2. two

| A | B |
| --- | --- |
| x | y |
>>
~ body.left == page.left + 96
~ body.right == page.right - 96
~ body.top == page.top - 96
end
