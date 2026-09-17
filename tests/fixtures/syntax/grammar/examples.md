# Syntax grammar examples

These parser fixtures remain available without the local design notes.

<!-- syntax: accept expression -->
```ss
style with {}
```

<!-- syntax: accept expression -->
```ss
style with {
  ;; No fields are updated.
  # The closing brace is still required.
}
```

<!-- syntax: accept expression -->
```ss
style with { body.size = 20 body.color = c"#123456", }
```

<!-- syntax: reject expression ExpectedIdentifier -->
```ss
style with {,}
```

<!-- syntax: reject module ExpectedChar -->
```ss
page Incomplete
let value = style with {
```

<!-- syntax: accept expression -->
```ss
text "A"
  ||
  (text <<
B
>>
    // text "C")
```

<!-- syntax: accept expression -->
```ss
a
;; Continue the same expression.
|=|
b |=| c
```

<!-- syntax: accept expression -->
```ss
a /=/ (b || c)
```

<!-- syntax: reject expression MixedCompositionDirections -->
```ss
a || b
// c
```

<!-- syntax: reject module ExpectedExpression -->
```ss
page Separate
let a = text("A");
|| text("B")
end
```

<!-- syntax: accept module -->
```ss
import std:core/prelude as { text, text!, place!, }
record Empty {}
record Style { size: Number = 20; color: Color = c"black" }
type Align = left | center | right
type Card = object {
  base = Object
  roles = ["card",]
  style: Style
}
extend Card { roles = ["extra"] }
const identity: (Number) -> Number = (x: Number) |-> x
fn consume(value: (Page -> Object)?, items: Selection<Object<Card>>) -> Void
  return
end
fn make(style: Style = Style {}) -> Style = style with {}
fn/! caption(label: String) -> Object = text(label)
document
end
page "Grammar examples"
  let a = text("A")
  let b = text "B"
  ~ a.left == page.left + 40
  ~ a.width == 100
  ~!~ a.top
  a.content = "Updated"
  if true
    text! // This is literal text.
  else
    place!(a || b)
  end
end
```

<!-- syntax: accept expression -->
```ss
text << # Header comment
A >> stays in the string
>> || text("B")
```

<!-- syntax: accept expression -->
```ss
text(<<
>>)
```

<!-- syntax: accept expression -->
```ss
"""
Literal text
"""
```

<!-- syntax: reject expression UnterminatedBlockString -->
```ss
text <<
Missing closing delimiter
```

<!-- syntax: accept expression -->
```ss
((x: Number, y: Number) |-> x + y)(1, 2)
```

<!-- syntax: accept expression -->
```ss
()
  |->
  text("A")
```

<!-- syntax: reject expression ExpectedIdentifier -->
```ss
[a, b]
```

<!-- syntax: reject module ImportMustBeAtTop -->
```ss
page First
end
import std:core/prelude
```

<!-- syntax: reject module ExpectedIdentifier -->
```ss
import std:core/prelude as {}
```

<!-- syntax: reject module RequiredParameterAfterDefault -->
```ss
fn invalid(a: Number = 1, b: Number) -> Number = a
```

<!-- syntax: reject module ExpectedReturn -->
```ss
fn invalid() -> Number
end
```

<!-- syntax: reject module ExpectedLineBreak -->
```ss
page Invalid
if true then
end
end
```

<!-- syntax: reject expression ExpectedIdentifier -->
```ss
.5
```

<!-- syntax: reject expression ExpectedIdentifier -->
```ss
+1
```

<!-- syntax: accept expression -->
```ss
c"""#123456"""
```

<!-- syntax: accept expression -->
```ss
a ?? b + c
```

<!-- syntax: accept expression -->
```ss
a + b ?? c
```

<!-- syntax: reject module ExpectedTypeAnnotation -->
```ss
type Direction = left |
right
```

<!-- syntax: reject expression ExpectedMemberName -->
```ss
value.
field
```

## Numeric comparisons

Numeric comparisons return `Bool` and bind less tightly than arithmetic.
Chained comparisons parse left to right and fail numeric type checking because
an intermediate result has type `Bool`. Constraint statements keep their
separate `~ target == source` syntax. Conditional blocks use a newline and `end`.

<!-- syntax: accept expression -->
```ss
phase + 1 == 2
```

<!-- syntax: accept expression -->
```ss
phase!=2
```

<!-- syntax: accept module -->
```ss
fn stop(phase: Number) -> Void
  if phase <= 2
    return
  end
end
```
