type CodeColors {
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
  addition: Color? = none
  deletion: Color? = none
  change: Color? = none
  addition_fill: Color? = none
  deletion_fill: Color? = none
  change_fill: Color? = none
}

type CodeHighlightTheme {
  code: CodeColors = CodeColors {}
  fill: Color? = none
  stroke: Color? = none
}
