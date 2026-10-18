import std:themes/default as *

page headings

let content = <<
# HeadingOne

BodyOne

## HeadingTwo

BodyTwo

### HeadingThree

BodyThree

#### HeadingFour

BodyFour

##### HeadingFive

BodyFive

###### HeadingSix

BodySix
>>
text!(content, default_text_style with {
  text.size = 18
  text.line_height = 24
  text.color = c"0.1,0.1,0.1"
  headings.h1 = MarkdownHeadingStyle { text = TextStyle { size = 44 line_height = 50 color = c"0.8,0.1,0.1" } }
  headings.h2 = MarkdownHeadingStyle { text = TextStyle { size = 36 line_height = 42 color = c"0.1,0.6,0.2" } }
  headings.h3 = MarkdownHeadingStyle { text = TextStyle { size = 28 line_height = 34 color = c"0.1,0.2,0.8" } }
  headings.h4 = MarkdownHeadingStyle { text = TextStyle { size = 24 line_height = 29 color = c"0.7,0.1,0.6" } }
  headings.h5 = MarkdownHeadingStyle { text = TextStyle { size = 20 line_height = 25 color = c"0.1,0.6,0.7" } }
  headings.h6 = MarkdownHeadingStyle { text = TextStyle { size = 18 line_height = 23 color = c"0.8,0.4,0.1" } }
})

end
