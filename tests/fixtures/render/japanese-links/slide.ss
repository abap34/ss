import std:themes/default as *

page copy_and_links
let title = h1!("日本語のコピーとリンク")
let body = text! <<
日本語の文章を選択してコピーしてください．

東京，大阪，京都．ひらがな，カタカナ，漢字．ABC 123．

[日本語を含む URL](https://ja.wikipedia.org/wiki/日本語)

[同じ URL を符号化したもの](https://ja.wikipedia.org/wiki/%E6%97%A5%E6%9C%AC%E8%AA%9E)

[日本語の名前を持つページ内の移動先](#日本語の移動先)
>>
~ title.left == page.left + 72
~ title.top == page.top - 56
~ body.left == page.left + 88
~ body.right == page.right - 88
~ body.top == title.bottom - 36
end

page destination
let title = h1!("日本語の移動先")
title.link_id = "日本語の移動先"
let body = text!("このページに移動できれば，内部リンクは正常です．")
~ title.left == page.left + 72
~ title.top == page.top - 56
~ body.left == page.left + 88
~ body.right == page.right - 88
~ body.top == title.bottom - 36
end
