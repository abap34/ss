import std:core/prelude as *

page Blocks
  let g = (text << ;; Description
A >> remains text
>>)
  |=| (text <<
B
>>
    //
    text << # Caption
C
>>)
  place!(g)
end
