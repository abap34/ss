import std:themes/default as *

page bold_sans
let heading = text!("[BOLD]:", default_theme().body with {
  text.size = 104
  text.line_height = 120
  text.font.family = "sans-serif"
  text.font.weight = 700
})
~ heading.left == page.left + 64
~ heading.top == page.top - 48

let mixed = text!("ALPHA [BETA]: 2026", default_theme().body with {
  text.size = 76
  text.line_height = 92
  text.font.family = "sans-serif"
  text.font.weight = 700
})
~ mixed.left == heading.left
~ mixed.top == heading.bottom - 24

let punctuation = text!("[] : :: ; ! ? ( ) { }", default_theme().body with {
  text.size = 84
  text.line_height = 100
  text.font.family = "sans-serif"
  text.font.weight = 700
})
~ punctuation.left == heading.left
~ punctuation.top == mixed.bottom - 24

let ascenders = text!("MWgjpqy [0:8]", default_theme().body with {
  text.size = 92
  text.line_height = 108
  text.font.family = "sans-serif"
  text.font.weight = 800
})
~ ascenders.left == heading.left
~ ascenders.top == punctuation.bottom - 24
end

page bold_monospace
let brackets = text!("[CODE]:", default_theme().body with {
  text.size = 104
  text.line_height = 120
  text.font.family = "monospace"
  text.font.weight = 700
})
~ brackets.left == page.left + 64
~ brackets.top == page.top - 48

let symbols = text!("AZaz09 [] : ; ! ?", default_theme().body with {
  text.size = 76
  text.line_height = 92
  text.font.family = "monospace"
  text.font.weight = 700
})
~ symbols.left == brackets.left
~ symbols.top == brackets.bottom - 24

let pairs = text!("[A:B] (C;D) {E!F} @#%&*", default_theme().body with {
  text.size = 72
  text.line_height = 88
  text.font.family = "monospace"
  text.font.weight = 700
})
~ pairs.left == brackets.left
~ pairs.top == symbols.bottom - 24

let metrics = text!("Hgjpqy_-=+ 00:11", default_theme().body with {
  text.size = 72
  text.line_height = 88
  text.font.family = "monospace"
  text.font.weight = 800
})
~ metrics.left == brackets.left
~ metrics.top == pairs.bottom - 24
end

page markdown_bold
let enclosed = text!("**[BOLD]:**", default_theme().body with {
  text.size = 96
  text.line_height = 112
  text.font.family = "sans-serif"
})
~ enclosed.left == page.left + 64
~ enclosed.top == page.top - 48

let outer = text!("[**BOLD**]:", default_theme().body with {
  text.size = 96
  text.line_height = 112
  text.font.family = "sans-serif"
})
~ outer.left == enclosed.left
~ outer.top == enclosed.bottom - 20

let mixed = text!("BEFORE [**BOLD**]: AFTER", default_theme().body with {
  text.size = 64
  text.line_height = 80
  text.font.family = "sans-serif"
})
~ mixed.left == enclosed.left
~ mixed.top == outer.bottom - 20

let punctuation = text!("**[] : :: ; ! ? ( ) { }**", default_theme().body with {
  text.size = 72
  text.line_height = 88
  text.font.family = "sans-serif"
})
~ punctuation.left == enclosed.left
~ punctuation.top == mixed.bottom - 20
end

page mixed_script_bold
let labels = text!("**[目的] [手法] [結果]**", default_theme().body with {
  text.size = 88
  text.line_height = 104
  text.font.family = "sans-serif"
})
~ labels.left == page.left + 64
~ labels.top == page.top - 48

let colon = text!("**実践的な改善手法のひとつ: 解析を複数に分割して段階的に行う**", default_theme().body with {
  text.size = 48
  text.line_height = 64
  text.font.family = "sans-serif"
})
~ colon.left == labels.left
~ colon.top == labels.bottom - 32

let brackets = text!("**[大括弧] (丸括弧) {波括弧} <山括弧>**", default_theme().body with {
  text.size = 64
  text.line_height = 80
  text.font.family = "sans-serif"
})
~ brackets.left == labels.left
~ brackets.top == colon.bottom - 32
end

page decorations
let underline = text!("_[UNDERLINE]: MWgjpqy 0:8_", default_theme().body with {
  text.size = 76
  text.line_height = 92
  text.font.family = "sans-serif"
})
~ underline.left == page.left + 64
~ underline.top == page.top - 64

let strike = text!("~~[STRIKE]: MWgjpqy 0:8~~", default_theme().body with {
  text.size = 76
  text.line_height = 92
  text.font.family = "sans-serif"
})
~ strike.left == underline.left
~ strike.top == underline.bottom - 48

let link = text!("[LINK: MWgjpqy 0:8](https://example.com/metrics)", default_theme().body with {
  text.size = 76
  text.line_height = 92
  text.font.family = "sans-serif"
})
~ link.left == underline.left
~ link.top == strike.bottom - 48
end
