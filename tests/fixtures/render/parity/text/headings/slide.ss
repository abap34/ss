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
text!(content, current_theme() with {
  body.text.size = 18
  body.text.line_height = 24
  body.text.color = c"0.1,0.1,0.1"
  h1.text.size = 44
  h1.text.line_height = 50
  h1.text.color = c"0.8,0.1,0.1"
  h1.layout.spacing_after = 19
  h2.text.size = 36
  h2.text.line_height = 42
  h2.text.color = c"0.1,0.6,0.2"
  h2.layout.spacing_after = 17
  h3.text.size = 28
  h3.text.line_height = 34
  h3.text.color = c"0.1,0.2,0.8"
  h3.layout.spacing_after = 15
  h4.text.size = 24
  h4.text.line_height = 29
  h4.text.color = c"0.7,0.1,0.6"
  h4.layout.spacing_after = 13
  h5.text.size = 20
  h5.text.line_height = 25
  h5.text.color = c"0.1,0.6,0.7"
  h5.layout.spacing_after = 11
  h6.text.size = 18
  h6.text.line_height = 23
  h6.text.color = c"0.8,0.4,0.1"
  h6.layout.spacing_after = 9
})

end
