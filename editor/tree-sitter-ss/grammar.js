const PREC = {
  call: 9,
  unary: 8,
  mul: 7,
  add: 6,
  concat: 5,
  coalesce: 4,
  compare: 3,
  composition: 2,
};

module.exports = grammar({
  name: "ss",

  extras: $ => [
    /[ \t\r]+/,
    $.comment,
  ],

  word: $ => $.identifier,

  externals: $ => [$._composition_newline],

  conflicts: $ => [
    [$.source_file],
  ],

  rules: {
    source_file: $ => seq(
      repeat($._terminator),
      repeat(seq($.import_declaration, repeat($._terminator))),
      repeat(choice($._top_level, $._terminator)),
    ),

    _top_level: $ => choice(
      $.const_declaration,
      $.function_declaration,
      $.type_declaration,
      $.object_extension,
      $.document_block,
      $.page_declaration,
    ),

    import_declaration: $ => seq(
      "import",
      field("spec", choice($.string, $.import_spec, $.identifier)),
      optional(seq("as", choice(field("alias", choice($.identifier, "*")), $.selected_imports))),
      $._terminator,
    ),

    selected_imports: $ => seq(
      "{",
      repeat($._terminator),
      commaSepNewline($, $.bare_callable_identifier),
      repeat($._terminator),
      "}",
    ),

    const_declaration: $ => seq(
      "const",
      field("name", $.identifier),
      ":",
      field("type", $.type),
      "=",
      field("value", $._expression),
      $._terminator,
    ),

    function_declaration: $ => seq(
      repeat(seq($.annotation, optional($._terminator))),
      choice(
        seq("fn", "/!", field("name", $.identifier)),
        seq("fn", field("name", $.bare_callable_identifier)),
      ),
      $.parameters,
      "->",
      field("result", $.type),
      repeat(seq($.annotation, optional($._terminator))),
      $._body,
    ),

    parameters: $ => seq("(", optional(commaSepNewline($, $.parameter)), ")"),
    parameter: $ => seq(field("name", $.identifier), ":", field("type", $.type), optional(seq("=", $._expression))),

    type_declaration: $ => seq(
      "type",
      field("name", $.type_identifier),
      "=",
      choice($.object_type, $.enum_type),
    ),

    enum_type: $ => seq(field("case", $.identifier), repeat(seq("|", field("case", $.identifier))), $._terminator),

    type: $ => choice(
      $.function_type,
      $.primary_type,
    ),

    object_type: $ => seq(
      choice("object", "protocol"),
      "{",
      repeat($._terminator),
      repeat($.object_member),
      "}",
    ),

    object_member: $ => choice($.object_base, $.object_implements, $.object_roles, $.object_field),
    object_base: $ => seq("base", "=", field("type", $._type_name), optional($._terminator)),
    object_implements: $ => seq("implements", "=", field("type", $._type_name), optional($._terminator)),
    object_roles: $ => seq("roles", "=", field("value", $.list_expression), optional($._terminator)),

    object_extension: $ => seq(
      "extend",
      field("target", $._type_name),
      "{",
      repeat($._terminator),
      repeat($.object_member),
      "}",
    ),

    object_field: $ => seq(field("name", $.identifier), ":", field("type", $.type), optional(seq("=", $._expression)), optional($._terminator)),

    document_block: $ => seq("document", $._body),

    page_declaration: $ => seq("page", field("name", choice($.string, $.identifier)), $._body),

    _body: $ => seq($._terminator, repeat($._statement), "end"),

    _statement: $ => choice(
      $.let_statement,
      $.return_statement,
      $.constrain_statement,
      $.constraint_update_statement,
      $.member_assignment_statement,
      $.property_statement,
      $.if_statement,
      $.for_statement,
      $.block_call_statement,
      $.expression_statement,
      $.line_call_statement,
    ),

    let_statement: $ => seq("let", field("name", $.identifier), "=", field("value", $._expression), $._terminator),
    return_statement: $ => seq("return", optional(field("value", $._expression)), $._terminator),
    constrain_statement: $ => seq("~", field("left", $.member_expression), "==", field("right", $._expression), $._terminator),
    constraint_update_statement: $ => seq(
      token(prec(1, "~!~")),
      field("target", $.member_expression),
      optional(seq("==", field("source", $._expression))),
      $._terminator,
    ),
    member_assignment_statement: $ => seq(field("target", $.member_expression), "=", field("value", $._expression), $._terminator),
    property_statement: $ => seq("property", field("target", $.identifier), field("key", $.string), field("value", $._expression), $._terminator),

    if_statement: $ => seq(
      "if",
      field("condition", $._expression),
      optional("then"),
      $._terminator,
      repeat($._statement),
      optional(seq("else", $._terminator, repeat($._statement))),
      "end",
      optional($._terminator),
    ),

    for_statement: $ => seq(
      "for",
      field("item", $.identifier),
      optional(seq(",", field("index", $.identifier))),
      "in",
      field("source", $._expression),
      $._terminator,
      repeat($._statement),
      "end",
      optional($._terminator),
    ),

    block_call_statement: $ => prec(PREC.call + 1, seq(field("function", $.callable_identifier), field("text", $.block_text), optional($._terminator))),
    line_call_statement: $ => choice(
      prec(PREC.call + 1, seq(field("function", $.callable_identifier), field("text", $.line_text), $._terminator)),
      prec(PREC.call + 2, seq(
        field("function", alias($._bang_line_callable, $.callable_identifier)),
        field("text", alias($._bang_line_text, $.line_text)),
        $._terminator,
      )),
    ),
    _bang_line_callable: $ => choice(
      alias($._bang_bare_callable, $.bare_callable_identifier),
      alias($._bang_qualified_callable, $.qualified_callable_identifier),
    ),
    _bang_bare_callable: $ => seq($.identifier, "!"),
    _bang_qualified_callable: $ => seq(
      field("module", $.identifier),
      "::",
      field("name", alias($._bang_bare_callable, $.bare_callable_identifier)),
    ),
    expression_statement: $ => seq($._expression, $._terminator),

    _expression: $ => choice(
      $.composition_expression,
      $.binary_expression,
      $.unary_expression,
      $.lambda_expression,
      $.property_default_expression,
      $.property_exists_expression,
      $.text_call_expression,
      $.call_expression,
      $.member_expression,
      $.if_expression,
      $.list_expression,
      $.identifier,
      $.string,
      $.color_string,
      $.number,
      $.boolean,
      $.block_text,
      $.parenthesized_expression,
    ),

    binary_expression: $ => choice(
      prec.left(PREC.compare, seq($._expression, choice("==", "!=", "<", "<=", ">", ">="), $._expression)),
      prec.left(PREC.mul, seq($._expression, choice("*", "/"), $._expression)),
      prec.left(PREC.add, seq($._expression, choice("+", "-"), $._expression)),
      prec.left(PREC.concat, seq($._expression, "++", $._expression)),
    ),

    // Retain mixed chains while editing so the compiler can diagnose the
    // missing parentheses without losing syntax highlighting for either side.
    composition_expression: $ => prec.left(PREC.composition, seq(
      field("left", $._expression),
      repeat($._composition_newline),
      field("operator", choice("||", "//", "|=|", "/=/")),
      repeat($._terminator),
      field("right", $._expression),
    )),

    unary_expression: $ => prec(PREC.unary, seq(choice("-", "!"), $._expression)),
    text_call_expression: $ => prec(PREC.call, seq(
      field("function", $.callable_identifier),
      field("text", choice($.string, $.block_text)),
    )),
    call_expression: $ => prec.left(PREC.call, seq(
      field("function", choice($.callable_identifier, $.parenthesized_expression, $.lambda_expression, $.call_expression)),
      "(",
      repeat($._terminator),
      optional(commaSepNewline($, $._expression)),
      repeat($._terminator),
      ")",
    )),
    member_expression: $ => prec(PREC.call, seq(
      field("object", choice($.identifier, $.call_expression, $.parenthesized_expression)),
      ".",
      field("member", $.identifier),
    )),
    property_default_expression: $ => prec.right(PREC.coalesce, seq(
      field("property", choice($.identifier, $.member_expression, $.call_expression, $.parenthesized_expression)),
      "??",
      field("default", $._expression),
    )),
    property_exists_expression: $ => prec(PREC.unary, seq(field("property", $.member_expression), "?")),
    if_expression: $ => seq("if", field("condition", $._expression), "then", field("then", $._expression), "else", field("else", $._expression), "end"),
    parenthesized_expression: $ => seq("(", repeat($._terminator), $._expression, repeat($._terminator), ")"),
    lambda_expression: $ => seq(
      field("parameters", $.lambda_parameters),
      repeat($._terminator),
      "|->",
      repeat($._terminator),
      field("body", $._expression),
    ),
    lambda_parameters: $ => seq("(", optional(commaSepNewline($, $.lambda_parameter)), ")"),
    lambda_parameter: $ => seq(field("name", $.identifier), ":", field("type", $.type)),
    list_expression: $ => seq("[", optional(commaSepNewline($, $._expression)), "]"),

    annotation: $ => seq("@", field("name", $.identifier), optional(seq("(", optional(commaSepNewline($, $.annotation_arg)), ")"))),
    annotation_arg: $ => choice(
      seq(field("name", $.identifier), "=", field("value", $.annotation_value)),
      $.annotation_value,
    ),
    annotation_value: $ => $._expression,

    function_type: $ => prec.right(1, choice(
      seq(field("param", $.primary_type), "->", field("result", $.type)),
      seq("(", optional(commaSepNewline($, $.type)), ")", "->", field("result", $.type)),
    )),

    primary_type: $ => choice(
      "document",
      "page",
      seq(choice("object", "Object"), optional(seq("<", $._type_name, ">"))),
      seq(choice("selection", "Selection"), optional(seq("<", $.type, ">"))),
      "anchor",
      "string",
      "number",
      "metadata",
      "bool",
      "boolean",
      "constraints",
      "void",
      "Void",
      seq("(", $.type, ")"),
      $._type_name,
    ),

    identifier: _ => /[A-Za-z_][A-Za-z0-9_]*/,
    callable_identifier: $ => prec(1, choice($.bare_callable_identifier, $.qualified_callable_identifier)),
    bare_callable_identifier: $ => prec(1, seq($.identifier, optional("!"))),
    qualified_callable_identifier: $ => prec(1, seq(field("module", $.identifier), "::", field("name", $.bare_callable_identifier))),
    import_spec: _ => /[A-Za-z0-9_./:-]+/,
    _type_name: $ => choice(alias($.identifier, $.type_identifier), $.qualified_type_identifier),
    qualified_type_identifier: $ => seq(field("module", $.identifier), "::", field("name", $.type_identifier)),
    type_identifier: _ => /[A-Z][A-Za-z0-9_]*/,
    string: _ => token(choice(
      seq('"""', repeat(choice(/[^"]+/, /"[^"]/, /""[^"]/)), '"""'),
      seq('"', repeat(/[^"]/), '"'),
    )),
    color_string: _ => /c"[^"]*"/,
    // Only a line-leading delimiter closes the literal. Leave its suffix and
    // newline to the surrounding expression, just like other string literals.
    block_text: _ => token(seq("<<", /[ \t\r]*(;;[^\n]*|#[^\n]*)?\n([ \t\r]*([^ \t\r>\n][^\n]*|>([^>\n][^\n]*)?)?\n)*[ \t\r]*>>/)),
    line_text: _ => token.immediate(/[ \t]+([^ \t|/"(<?\n][^\n]*|\|([^|=\n][^\n]*|=([^|\n][^\n]*)?)?|\/([^/=\n][^\n]*|=([^/\n][^\n]*)?)?|<([^<\n][^\n]*)?|\?([^?\n][^\n]*)?)/),
    _bang_line_text: _ => token.immediate(/[ \t]+([^ \t"(<\n][^\n]*|<([^<\n][^\n]*)?)/),
    number: _ => /\d+(\.\d+)?/,
    boolean: _ => choice("true", "false"),
    comment: _ => token(choice(/;;[^\n]*/, /#[^\n]*/)),
    _terminator: _ => /\n+/,
  },
});

function commaSep(rule) {
  return seq(rule, repeat(seq(",", rule)), optional(","));
}

function commaSepNewline($, rule) {
  return seq(
    rule,
    repeat(seq(repeat($._terminator), ",", repeat($._terminator), rule)),
    optional(seq(repeat($._terminator), ",")),
  );
}
