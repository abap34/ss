[
  "import"
  "const"
  "document"
  "page"
  "fn"
  "let"
  "return"
  "end"
  "constrain"
  "property"
  "type"
  "extend"
  "protocol"
  "base"
  "implements"
  "roles"
  "if"
  "then"
  "else"
  "for"
  "in"
] @keyword

[
  "->"
  "|->"
  "??"
  "?"
  "++"
  "=="
  "="
  ":"
  "|"
  "."
  ","
  "!"
  "<"
  ">"
  "-"
  "+"
  "*"
  "/"
] @operator

(comment) @comment
(string) @string
(block_text) @string
(color_string) @string.special
(number) @number
(boolean) @constant.builtin
(type) @type
(type_identifier) @type

(function_declaration name: (identifier) @function)
(call_expression function: (identifier) @function.call)
(text_call_expression function: (identifier) @function.call)
(line_call_statement function: (identifier) @function.call)
(block_call_statement function: (identifier) @function.call)
(parameter name: (identifier) @variable.parameter)
(lambda_parameter name: (identifier) @variable.parameter)
(let_statement name: (identifier) @variable)
(object_field name: (identifier) @property)
(member_expression member: (identifier) @property)
(annotation name: (identifier) @attribute)
