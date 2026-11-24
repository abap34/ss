import std:code as code_api

const patch: String = <<
--- a/sample.txt
+++ b/sample.txt
@@ -1,2 +1,2 @@
-removed text
+added text
 unchanged context
!changed text
>>

page code
  code!(patch, "diff")
end

page markdown
  text!("```diff" ++ NEWLINE ++ patch ++ NEWLINE ++ "```")
end

page custom
  let colors = code_api::CodeColors {
    addition = c"#118833"
    deletion = c"#bb2233"
    change = c"#aa7700"
    addition_fill = c"#d5f5e3"
    deletion_fill = c"#fadbd8"
    change_fill = c"#fcf3cf"
  }
  code!(patch, "diff", default_text_style with { code.colors = colors })
end

page dark
  let palette = code_api::code_theme_github_dark()
  code!(patch, "diff", default_text_style with {
    code.colors = palette.code
    code.chrome.fill = palette.fill
    code.chrome.stroke = palette.stroke
  })
end

page no_background
  code!(patch, "diff", default_text_style with {
    code.colors.addition_fill = none
    code.colors.deletion_fill = none
    code.colors.change_fill = none
  })
end
