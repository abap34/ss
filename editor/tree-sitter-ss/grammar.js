const PREC = {
  call: 11,
  unary: 10,
  mul: 9,
  add: 8,
  concat: 7,
  coalesce: 6,
  compare: 5,
  intersection: 4,
  union: 3,
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
    [$.qualified_identifier, $.bare_callable_identifier],
    [$.bare_callable_identifier, $.qualified_type_identifier],
    [$.qualified_identifier, $.bare_callable_identifier, $.qualified_type_identifier],
    [$._bang_bare_callable, $.bare_callable_identifier],
    [$.bare_callable_identifier, $._type_name],
    [$._expression, $.bare_callable_identifier, $._type_name],
    [$._expression, $.bare_callable_identifier],
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
      $.enum_declaration,
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
        seq("fn/!", field("name", $.identifier)),
        seq("fn", field("name", $.bare_callable_identifier)),
      ),
      optional($.type_parameters),
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
      field("name", alias($.identifier, $.type_identifier)),
      optional($.type_parameters),
      $.type_body,
    ),

    enum_declaration: $ => seq(
      "enum",
      field("name", alias($.identifier, $.type_identifier)),
      "{",
      repeat($._terminator),
      repeat1(seq(field("case", $.identifier), repeat($._terminator))),
      "}",
    ),

    type_parameters: $ => seq("<", typeList($, $.type_parameter), ">"),
    type_parameter: $ => field("name", alias($.identifier, $.type_identifier)),
    type_arguments: $ => seq("<", typeList($, $.type), ">"),

    type: $ => choice(
      $.function_type,
      $.optional_type,
      $.primary_type,
    ),

    optional_type: $ => seq($.primary_type, "?"),

    type_body: $ => seq("{", repeat($._terminator), repeat($.type_field), "}"),

    type_field: $ => seq(field("name", $.identifier), ":", field("type", $.type), optional(seq("=", $._expression)), optional($._terminator)),

    document_block: $ => seq("document", $._body),

    page_declaration: $ => seq("page", field("name", choice($.string, $.identifier)), $._terminator, optional($.stages_declaration), repeat($._statement), "end"),

    stages_declaration: $ => seq("stages", field("name", $.identifier), "{", repeat($._terminator), repeat1(seq(field("stage", $.identifier), repeat($._terminator))), "}", $._terminator),

    _body: $ => seq($._terminator, repeat($._statement), "end"),

    _statement: $ => choice(
      $.let_statement,
      $.return_statement,
      $.constrain_statement,
      $.constraint_update_statement,
      $.member_assignment_statement,
      $.if_statement,
      $.show_statement,
      $.block_call_statement,
      $.expression_statement,
      $.line_call_statement,
    ),

    let_statement: $ => seq("let", field("name", $.identifier), optional(seq(":", field("type", $.type))), "=", field("value", $._expression), $._terminator),
    return_statement: $ => seq("return", optional(field("value", $._expression)), $._terminator),
    constrain_statement: $ => seq(optional(field("page", $._expression)), "~", field("value", $._expression), $._terminator),
    constraint_update_statement: $ => seq(
      token(prec(1, "~!~")),
      field("target", $.member_expression),
      optional(seq("==", field("source", $._expression))),
      $._terminator,
    ),
    member_assignment_statement: $ => seq(field("target", $.member_expression), "=", field("value", $._expression), $._terminator),

    show_statement: $ => seq("show", field("condition", $._expression), $._body, optional($._terminator)),

    if_statement: $ => seq(
      "if",
      field("condition", $._expression),
      $._terminator,
      repeat($._statement),
      optional(seq("else", $._terminator, repeat($._statement))),
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
      $.value_construction,
      $.value_update_expression,
      $.member_expression,
      $.identifier,
      $.qualified_identifier,
      alias($._bang_bare_callable, $.bare_callable_identifier),
      alias($._bang_qualified_callable, $.qualified_callable_identifier),
      $.string,
      $.color_string,
      $.number,
      $.boolean,
      $.block_text,
      $.parenthesized_expression,
    ),

    binary_expression: $ => choice(
      prec.left(PREC.union, seq($._expression, "|", $._expression)),
      prec.left(PREC.intersection, seq($._expression, "&", $._expression)),
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
      choice(
        seq(field("function", $.callable_identifier), optional($.type_arguments)),
        field("function", choice($.parenthesized_expression, $.lambda_expression, $.call_expression)),
      ),
      "(",
      repeat($._terminator),
      optional(commaSepNewline($, $._expression)),
      repeat($._terminator),
      ")",
    )),
    value_construction: $ => prec(PREC.call, seq(
      field("type", $._type_name),
      optional($.type_arguments),
      "{",
      repeat($._terminator),
      repeat(seq($.value_field, optional(","), repeat($._terminator))),
      "}",
    )),
    value_update_expression: $ => prec.left(PREC.call, seq(
      field("value", choice($.identifier, $.qualified_identifier, $.value_construction, $.value_update_expression, $.member_expression, $.call_expression, $.parenthesized_expression)),
      "with",
      "{",
      repeat($._terminator),
      repeat(seq($.value_update_field, optional(","), repeat($._terminator))),
      "}",
    )),
    value_update_field: $ => seq(field("path", $.value_field_path), "=", field("value", $._expression)),
    value_field_path: $ => seq($.identifier, repeat(seq(".", $.identifier))),
    value_field: $ => seq(field("name", $.identifier), "=", field("value", $._expression)),
    member_expression: $ => prec.left(PREC.call, seq(
      field("object", choice($.identifier, $.qualified_identifier, $.value_construction, $.value_update_expression, $.call_expression, $.member_expression, $.parenthesized_expression)),
      choice(".", "?."),
      field("member", $.identifier),
    )),
    property_default_expression: $ => prec.right(PREC.coalesce, seq(
      field("property", choice($.identifier, $.qualified_identifier, $.member_expression, $.call_expression, $.parenthesized_expression)),
      "??",
      field("default", $._expression),
    )),
    property_exists_expression: $ => prec(PREC.unary, seq(
      field("property", choice($.identifier, $.qualified_identifier, $.member_expression, $.call_expression, $.parenthesized_expression)),
      "?",
    )),
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

    annotation: $ => seq("@", field("name", $.identifier), optional(seq("(", optional(commaSepNewline($, $.annotation_arg)), ")"))),
    annotation_arg: $ => choice(
      seq(field("name", $.identifier), "=", field("value", $.annotation_value)),
      $.annotation_value,
    ),
    annotation_value: $ => $._expression,

    function_type: $ => prec.right(1, choice(
      seq(field("param", choice($.primary_type, $.optional_type)), "->", field("result", $.type)),
      seq("(", optional(commaSepNewline($, $.type)), ")", "->", field("result", $.type)),
    )),

    primary_type: $ => choice(
      seq("(", $.type, ")"),
      seq($._type_name, optional($.type_arguments)),
    ),

    identifier: _ => /[A-Za-z_][A-Za-z0-9_]*/,
    qualified_identifier: $ => seq(field("module", $.identifier), "::", field("name", $.identifier)),
    callable_identifier: $ => choice($.bare_callable_identifier, $.qualified_callable_identifier),
    bare_callable_identifier: $ => seq($.identifier, optional("!")),
    qualified_callable_identifier: $ => prec(1, seq(field("module", $.identifier), "::", field("name", $.bare_callable_identifier))),
    import_spec: _ => /[A-Za-z0-9_./:-]+/,
    _type_name: $ => choice(alias($.identifier, $.type_identifier), $.qualified_type_identifier),
    qualified_type_identifier: $ => seq(field("module", $.identifier), "::", field("name", alias($.identifier, $.type_identifier))),
    string: _ => /"[^"]*"/,
    color_string: _ => /c"[^"]*"/,
    // Only a line-leading delimiter closes the literal. Leave its suffix and
    // newline to the surrounding expression, just like other string literals.
    block_text: _ => token(seq("<<", /[ \t\r]*(;;[^\n]*)?\n([ \t\r]*([^ \t\r>\n][^\n]*|>([^>\n][^\n]*)?)?\n)*[ \t\r]*>>/)),
    line_text: _ => token.immediate(/[ \t]+([^ \t|&/"(<?~\n][^\n]*|\|->[^\n]*|\/([^/=\n][^\n]*|=([^/\n][^\n]*)?)?|<([^<\n][^\n]*)?|\?([^?\n][^\n]*)?)/),
    _bang_line_text: _ => token.immediate(/[ \t]+([^ \t"(<\n][^\n]*|<([^<\n][^\n]*)?)/),
    number: _ => /\d+(\.\d+)?/,
    boolean: _ => choice("true", "false"),
    comment: _ => token(/;;[^\n]*/),
    _terminator: _ => /\n+/,
  },
});

function commaSepNewline($, rule) {
  return seq(
    rule,
    repeat(seq(repeat($._terminator), ",", repeat($._terminator), rule)),
    optional(seq(repeat($._terminator), ",")),
  );
}

function typeList($, rule) {
  return seq(
    repeat($._terminator),
    rule,
    repeat(seq(repeat($._terminator), ",", repeat($._terminator), rule)),
    repeat($._terminator),
  );
}
