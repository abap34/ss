import std:themes/default as *

page code_lines
text! <<
# Code line highlights

```zig {2-3,5}
fn add(a: i32, b: i32) i32 {
    const x = a;
    const y = b;

    return x + y;
}
```

``` {1,3}

A blank line above and below is highlighted.

```
>>
end

page custom_color
let note = text! <<
```python {3,1-2,2}
def greet(name):
    message = f"Hello, {name}!"
    print(message)
```
>>
note.text.markdown_code_highlight_fill = c"#b9f6ca"
let plain = text! <<
```zig {1}
const disabled = true;
```
>>
plain.text.markdown_code_highlight_fill = none
end
