[
  (document_block
    "document" @start.document
    "end" @end)
  (page_declaration
    "page" @start.page
    "end" @end)
  (function_declaration
    "fn" @start.fn
    "end" @end)
  (if_statement
    "if" @start.if
    "end" @end)
  (for_statement
    "for" @start.for
    "end" @end)
  (object_type
    "object" @start.object
    "}" @end)
  (object_type
    "protocol" @start.object
    "}" @end)
  (object_extension
    "extend" @start.extend
    "}" @end)
  (parameters)
  (lambda_parameters)
  (list_expression)
  (parenthesized_expression)
  (call_expression)
] @indent

(if_statement "else" @outdent)
