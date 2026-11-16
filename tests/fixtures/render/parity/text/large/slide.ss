import std:themes/default as *

page bold_sans
let heading = text!("[BOLD]:", default_theme().text with {
  size = 104
  line_height = 120
  font.family = "sans-serif"
  font.weight = 700
})
~ heading.left == page.left + 64
~ heading.top == page.top - 48

let mixed = text!("ALPHA [BETA]: 2026", default_theme().text with {
  size = 76
  line_height = 92
  font.family = "sans-serif"
  font.weight = 700
})
~ mixed.left == heading.left
~ mixed.top == heading.bottom - 24

let punctuation = text!("[] : :: ; ! ? ( ) { }", default_theme().text with {
  size = 84
  line_height = 100
  font.family = "sans-serif"
  font.weight = 700
})
~ punctuation.left == heading.left
~ punctuation.top == mixed.bottom - 24

let ascenders = text!("MWgjpqy [0:8]", default_theme().text with {
  size = 92
  line_height = 108
  font.family = "sans-serif"
  font.weight = 800
})
~ ascenders.left == heading.left
~ ascenders.top == punctuation.bottom - 24
end

page bold_monospace
let brackets = text!("[CODE]:", default_theme().text with {
  size = 104
  line_height = 120
  font.family = "monospace"
  font.weight = 700
})
~ brackets.left == page.left + 64
~ brackets.top == page.top - 48

let symbols = text!("AZaz09 [] : ; ! ?", default_theme().text with {
  size = 76
  line_height = 92
  font.family = "monospace"
  font.weight = 700
})
~ symbols.left == brackets.left
~ symbols.top == brackets.bottom - 24

let pairs = text!("[A:B] (C;D) {E!F} @#%&*", default_theme().text with {
  size = 72
  line_height = 88
  font.family = "monospace"
  font.weight = 700
})
~ pairs.left == brackets.left
~ pairs.top == symbols.bottom - 24

let metrics = text!("Hgjpqy_-=+ 00:11", default_theme().text with {
  size = 72
  line_height = 88
  font.family = "monospace"
  font.weight = 800
})
~ metrics.left == brackets.left
~ metrics.top == pairs.bottom - 24
end

page markdown_bold
let enclosed = text!("**[BOLD]:**", default_theme().text with {
  size = 96
  line_height = 112
  font.family = "sans-serif"
})
~ enclosed.left == page.left + 64
~ enclosed.top == page.top - 48

let outer = text!("[**BOLD**]:", default_theme().text with {
  size = 96
  line_height = 112
  font.family = "sans-serif"
})
~ outer.left == enclosed.left
~ outer.top == enclosed.bottom - 20

let mixed = text!("BEFORE [**BOLD**]: AFTER", default_theme().text with {
  size = 64
  line_height = 80
  font.family = "sans-serif"
})
~ mixed.left == enclosed.left
~ mixed.top == outer.bottom - 20

let punctuation = text!("**[] : :: ; ! ? ( ) { }**", default_theme().text with {
  size = 72
  line_height = 88
  font.family = "sans-serif"
})
~ punctuation.left == enclosed.left
~ punctuation.top == mixed.bottom - 20
end

page mixed_script_bold
let labels = text!("**[目的] [手法] [結果]**", default_theme().text with {
  size = 88
  line_height = 104
  font.family = "sans-serif"
})
~ labels.left == page.left + 64
~ labels.top == page.top - 48

let colon = text!("**実践的な改善手法のひとつ: 解析を複数に分割して段階的に行う**", default_theme().text with {
  size = 48
  line_height = 64
  font.family = "sans-serif"
})
~ colon.left == labels.left
~ colon.top == labels.bottom - 32

let brackets = text!("**[大括弧] (丸括弧) {波括弧} <山括弧>**", default_theme().text with {
  size = 64
  line_height = 80
  font.family = "sans-serif"
})
~ brackets.left == labels.left
~ brackets.top == colon.bottom - 32
end

page decorations
let underline = text!("_[UNDERLINE]: MWgjpqy 0:8_", default_theme().text with {
  size = 76
  line_height = 92
  font.family = "sans-serif"
})
~ underline.left == page.left + 64
~ underline.top == page.top - 64

let strike = text!("~~[STRIKE]: MWgjpqy 0:8~~", default_theme().text with {
  size = 76
  line_height = 92
  font.family = "sans-serif"
})
~ strike.left == underline.left
~ strike.top == underline.bottom - 48

let link = text!("[LINK: MWgjpqy 0:8](https://example.com/metrics)", default_theme().text with {
  size = 76
  line_height = 92
  font.family = "sans-serif"
})
~ link.left == underline.left
~ link.top == strike.bottom - 48
end
