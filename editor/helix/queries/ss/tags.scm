(function_declaration
  name: [(identifier) (callable_identifier)] @name) @definition.function

(const_declaration
  name: (identifier) @name) @definition.constant

(page_declaration
  name: [(identifier) (string)] @name) @definition.class

(type_declaration
  name: (type_identifier) @name) @definition.type

(object_extension
  target: (type_identifier) @name) @definition.type

(object_field
  name: (identifier) @name) @definition.field
