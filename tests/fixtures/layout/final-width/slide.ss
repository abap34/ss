import std:themes/default as *

page wrap_enabled
let table = text! <<
| content | value |
| --- | --- |
| one two three four five six seven eight nine ten | A |
| one two three four five six seven eight nine ten | B |
>>
table.layout.wrap = WrapMode.on
~ table.left == page.left + 60
~ table.right == table.left + 220
~ table.top == page.top - 80
let after = text!("After table")
~ after.left == table.left
~ after.top == table.bottom - 20
end

page wrap_disabled
let table = text! <<
| content | value |
| --- | --- |
| one two three four five six seven eight nine ten | A |
| one two three four five six seven eight nine ten | B |
>>
table.layout.wrap = WrapMode.off
~ table.left == page.left + 60
~ table.right == table.left + 220
~ table.top == page.top - 80
let after = text!("After table")
~ after.left == table.left
~ after.top == table.bottom - 20
end
