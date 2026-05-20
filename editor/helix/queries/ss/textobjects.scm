(function_declaration) @function.around
(function_declaration
  (parameters) @function.inside)

(page_declaration) @class.around
(document_block) @class.around

(block_text) @comment.inside
(comment)+ @comment.around
