import std:themes/default as *

page bold_sans
let heading = text!("[BOLD]:")
heading.text.size = 104
heading.text.line_height = 120
heading.text.font.family = "sans-serif"
heading.text.font.weight = 700
~ heading.left == page.left + 64
~ heading.top == page.top - 48

let mixed = text!("ALPHA [BETA]: 2026")
mixed.text.size = 76
mixed.text.line_height = 92
mixed.text.font.family = "sans-serif"
mixed.text.font.weight = 700
~ mixed.left == heading.left
~ mixed.top == heading.bottom - 24

let punctuation = text!("[] : :: ; ! ? ( ) { }")
punctuation.text.size = 84
punctuation.text.line_height = 100
punctuation.text.font.family = "sans-serif"
punctuation.text.font.weight = 700
~ punctuation.left == heading.left
~ punctuation.top == mixed.bottom - 24

let ascenders = text!("MWgjpqy [0:8]")
ascenders.text.size = 92
ascenders.text.line_height = 108
ascenders.text.font.family = "sans-serif"
ascenders.text.font.weight = 800
~ ascenders.left == heading.left
~ ascenders.top == punctuation.bottom - 24
end

page bold_monospace
let brackets = text!("[CODE]:")
brackets.text.size = 104
brackets.text.line_height = 120
brackets.text.font.family = "monospace"
brackets.text.font.weight = 700
~ brackets.left == page.left + 64
~ brackets.top == page.top - 48

let symbols = text!("AZaz09 [] : ; ! ?")
symbols.text.size = 76
symbols.text.line_height = 92
symbols.text.font.family = "monospace"
symbols.text.font.weight = 700
~ symbols.left == brackets.left
~ symbols.top == brackets.bottom - 24

let pairs = text!("[A:B] (C;D) {E!F} @#%&*")
pairs.text.size = 72
pairs.text.line_height = 88
pairs.text.font.family = "monospace"
pairs.text.font.weight = 700
~ pairs.left == brackets.left
~ pairs.top == symbols.bottom - 24

let metrics = text!("Hgjpqy_-=+ 00:11")
metrics.text.size = 72
metrics.text.line_height = 88
metrics.text.font.family = "monospace"
metrics.text.font.weight = 800
~ metrics.left == brackets.left
~ metrics.top == pairs.bottom - 24
end

page markdown_bold
let enclosed = text!("**[BOLD]:**")
enclosed.text.size = 96
enclosed.text.line_height = 112
enclosed.text.font.family = "sans-serif"
~ enclosed.left == page.left + 64
~ enclosed.top == page.top - 48

let outer = text!("[**BOLD**]:")
outer.text.size = 96
outer.text.line_height = 112
outer.text.font.family = "sans-serif"
~ outer.left == enclosed.left
~ outer.top == enclosed.bottom - 20

let mixed = text!("BEFORE [**BOLD**]: AFTER")
mixed.text.size = 64
mixed.text.line_height = 80
mixed.text.font.family = "sans-serif"
~ mixed.left == enclosed.left
~ mixed.top == outer.bottom - 20

let punctuation = text!("**[] : :: ; ! ? ( ) { }**")
punctuation.text.size = 72
punctuation.text.line_height = 88
punctuation.text.font.family = "sans-serif"
~ punctuation.left == enclosed.left
~ punctuation.top == mixed.bottom - 20
end

page mixed_script_bold
let labels = text!("**[目的] [手法] [結果]**")
labels.text.size = 88
labels.text.line_height = 104
labels.text.font.family = "sans-serif"
~ labels.left == page.left + 64
~ labels.top == page.top - 48

let colon = text!("**実践的な改善手法のひとつ: 解析を複数に分割して段階的に行う**")
colon.text.size = 48
colon.text.line_height = 64
colon.text.font.family = "sans-serif"
~ colon.left == labels.left
~ colon.top == labels.bottom - 32

let brackets = text!("**[大括弧] (丸括弧) {波括弧} <山括弧>**")
brackets.text.size = 64
brackets.text.line_height = 80
brackets.text.font.family = "sans-serif"
~ brackets.left == labels.left
~ brackets.top == colon.bottom - 32
end

page decorations
let underline = text!("_[UNDERLINE]: MWgjpqy 0:8_")
underline.text.size = 76
underline.text.line_height = 92
underline.text.font.family = "sans-serif"
~ underline.left == page.left + 64
~ underline.top == page.top - 64

let strike = text!("~~[STRIKE]: MWgjpqy 0:8~~")
strike.text.size = 76
strike.text.line_height = 92
strike.text.font.family = "sans-serif"
~ strike.left == underline.left
~ strike.top == underline.bottom - 48

let link = text!("[LINK: MWgjpqy 0:8](https://example.com/metrics)")
link.text.size = 76
link.text.line_height = 92
link.text.font.family = "sans-serif"
~ link.left == underline.left
~ link.top == strike.bottom - 48
end
