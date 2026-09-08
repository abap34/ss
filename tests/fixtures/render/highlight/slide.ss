import std:themes/default as *

page highlighted_code
let snippet = <<
# Nested expressions and overlapping captures
def format_value(value):
    message = f"value: {value + 1}"
    return print(message)
>>
code!(snippet, "python")
end

page highlighted_markdown
text! <<
Code within Markdown:

```javascript
function display(value) {
  const text = `value: ${value + 1}`;
  return console.log(text);
}
```
>>
end
