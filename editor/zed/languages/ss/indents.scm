[
  (document_block
    "document" @start.document
    "end" @end)
  (page_declaration
    "page" @start.page
    "end" @end)
  (function_declaration
    ["fn" "fn/!"] @start.fn
    "end" @end)
  (if_statement
    "if" @start.if
    "end" @end)
  (type_body
    "{" @start.type
    "}" @end)
  (enum_declaration
    "{" @start.enum
    "}" @end)
  (value_update_expression
    "{" @start.update
    "}" @end)
  (parameters)
  (lambda_parameters)
  (parenthesized_expression)
  (call_expression)
] @indent

(if_statement "else" @outdent)
