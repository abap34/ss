import std:themes/default as *

page scheme_code
let snippet = <<
; Compute a square
(define (square x) (* x x))
(display "hello")
(square 42)
#t #f #\space
'(one two) `(+ ,value 1)
#| Outer #| nested |# comment |#
#;(ignored datum)
>>
code!(snippet, "scheme")
end

page scheme_markdown
text! <<
```scm
; Scheme in Markdown
(define answer 42)
(display "hello")
```
>>
end
