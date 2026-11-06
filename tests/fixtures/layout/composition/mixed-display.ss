page _
  let theme = default_theme()
  let text_item = text! <<
Context-sensitive and field-sensitive analysis

Valid paths form an interleaved Dyck language.
>>

  let group_item = text! <<
```c
struct Box { int f; };

struct Box *wrap(int v) {
  struct Box *r = calloc(1, sizeof *r);
  r->f = v;
  return r;
}

int p = require_password();
struct Box *b = wrap(p);
log(b->f);
```
>>
  |=|
  pdf!("asset.pdf", theme.pdf with { asset.scale = 0.8 })

  ~!~ text_item.left == page.left + 306.15
  ~!~ text_item.top == page.top - 136.03
  ~!~ group_item.left == page.left + 96
  ~!~ group_item.top == page.top - 232.96
end
