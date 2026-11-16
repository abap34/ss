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
  size = 18
  line_height = 24
  color = c"0.1,0.1,0.1"
  headings.h1 = TypographyOverride { size = 44 line_height = 50 color = c"0.8,0.1,0.1" }
  headings.h2 = TypographyOverride { size = 36 line_height = 42 color = c"0.1,0.6,0.2" }
  headings.h3 = TypographyOverride { size = 28 line_height = 34 color = c"0.1,0.2,0.8" }
  headings.h4 = TypographyOverride { size = 24 line_height = 29 color = c"0.7,0.1,0.6" }
  headings.h5 = TypographyOverride { size = 20 line_height = 25 color = c"0.1,0.6,0.7" }
  headings.h6 = TypographyOverride { size = 18 line_height = 23 color = c"0.8,0.4,0.1" }
})

end
