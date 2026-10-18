import std:prelude as *

page Blocks
  let g = (text << ;; Description
A >> remains text
>>)
  |=| (text <<
B
>>
    //
    text << ;; Caption
C
>>)
  place_on!(pagectx(), g)
end
