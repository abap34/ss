import std:prelude as *
import std:text/style as { TextBlockStyle, default_text_style }

const body: TextBlockStyle = default_text_style with {
  text.size = 28
  text.line_height = 36
  layout.spacing_after = 28
}
const asset: AssetBlockStyle = AssetBlockStyle {} with {
  chrome.fill = c"1,1,1"
  chrome.pad_x = 12
  chrome.pad_y = 10
}

fn head!(title: String) -> Placed<Group<Heading, PathShape>>
  let label = heading!(title, 3, body with { text.size = 40 text.line_height = 48 })
  let rule = line!(1136, 2)
  ~ label.left == page.left + 72
  ~ label.top == page.top - 56
  ~ rule.left == label.left
  ~ rule.top == label.bottom
  return group!(label, rule)
end

page list_and_pdf
  vflow(LayoutPolicy.center)
  head!("Reachability analysis")
  text!("## Context-free conditions in program analysis", body)
  text!(<<
1. Analysis conditions often describe matching pairs of operations.
   - Examples include allocating and freeing memory, or acquiring and releasing a lock.
2. Function calls and returns also form matching pairs.
   - Conditions for analysis inside one procedure can be extended to analysis across procedure boundaries.
>>, body)
  |=|
  pdf!("list.pdf", asset with { asset.scale = 0.75 })
end

page code_and_pdf
  vflow(LayoutPolicy.center)
  head!("Field-sensitive analysis")
  text!("A false positive reports a leak even though no password can escape.", body)
  text!(<<
```c
struct Box { int f; int g; struct Box *next;};

int p = require_password();
struct Box *b = calloc(1, sizeof(struct Box));
b->g = 0;
b->f = p;
log(b->g);   // OK
log(b->f);   // Leak
```
>>, body)
  |=|
  pdf!("code.pdf", asset)
end
