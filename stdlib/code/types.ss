type CodeColors = record {
  plain: Color? = none
  keyword: Color? = none
  function: Color? = none
  type_name: Color? = none
  constant: Color? = none
  number: Color? = none
  variable: Color? = none
  operator: Color? = none
  comment: Color? = none
  string: Color? = none
}

type CodeHighlightTheme = record {
  code: CodeColors = CodeColors {}
  fill: Color? = none
  stroke: Color? = none
}
