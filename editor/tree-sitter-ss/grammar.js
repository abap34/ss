const PREC = {
  call: 8,
  unary: 7,
  mul: 6,
  add: 5,
  concat: 4,
  compare: 3,
};

module.exports = grammar({
  name: "ss",

  extras: $ => [
    /[ \t\r]+/,
    $.comment,
  ],

  word: $ => $.identifier,

  rules: {
    source_file: $ => repeat(choice($._top_level, $._terminator)),

    _top_level: $ => choice(
      $.import_declaration,
      $.const_declaration,
      $.function_declaration,
      $.type_declaration,
      $.object_extension,
      $.document_block,
      $.page_declaration,
    ),

    import_declaration: $ => seq("import", field("spec", choice($.string, $.import_spec, $.identifier)), $._terminator),

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
      "fn",
      field("name", $.identifier),
      $.parameters,
      "->",
      field("result", $.type),
      optional($.effect_clause),
      repeat(seq($.annotation, optional($._terminator))),
      $._body,
    ),

    parameters: $ => seq("(", optional(commaSepNewline($, $.parameter)), ")"),
    parameter: $ => seq(field("name", $.identifier), ":", field("type", $.type), optional(seq("=", $._expression))),
    effect_clause: $ => seq("!", $.identifier, repeat(seq("|", $.identifier))),

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
    object_base: $ => seq("base", "=", field("type", $.type_identifier), optional($._terminator)),
    object_implements: $ => seq("implements", "=", field("type", $.type_identifier), optional($._terminator)),
    object_roles: $ => seq("roles", "=", field("value", $.list_expression), optional($._terminator)),

    object_extension: $ => seq(
      "extend",
      field("target", $.type_identifier),
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
    constrain_statement: $ => seq("~", field("left", $._expression), "==", field("right", $._expression), optional(seq(choice("+", "-"), $._expression)), $._terminator),
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

    block_call_statement: $ => prec(PREC.call + 1, seq(field("function", $.identifier), field("text", $.block_text), optional($._terminator))),
    line_call_statement: $ => prec(PREC.call + 1, seq(field("function", $.identifier), field("text", $.line_text), $._terminator)),
    expression_statement: $ => seq($._expression, $._terminator),

    _expression: $ => choice(
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
      prec.left(PREC.mul, seq($._expression, choice("*", "/"), $._expression)),
      prec.left(PREC.add, seq($._expression, choice("+", "-"), $._expression)),
      prec.left(PREC.concat, seq($._expression, "++", $._expression)),
    ),

    unary_expression: $ => prec(PREC.unary, seq("-", $._expression)),
    text_call_expression: $ => prec(PREC.call, seq(
      field("function", $.identifier),
      field("text", choice($.string, $.block_text)),
    )),
    call_expression: $ => prec.left(PREC.call, seq(
      field("function", choice($.identifier, $.parenthesized_expression, $.lambda_expression, $.call_expression)),
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
    property_default_expression: $ => prec.right(PREC.compare, seq(field("property", $.member_expression), "??", field("default", $._expression))),
    property_exists_expression: $ => prec(PREC.unary, seq(field("property", $.member_expression), "?")),
    if_expression: $ => seq("if", field("condition", $._expression), "then", field("then", $._expression), "else", field("else", $._expression), "end"),
    parenthesized_expression: $ => seq("(", $._expression, ")"),
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
      seq("object", optional(seq("<", $.type_identifier, ">"))),
      seq("selection", optional(seq("<", $.type, ">"))),
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
      $.type_identifier,
    ),

    identifier: _ => /[A-Za-z_][A-Za-z0-9_]*/,
    import_spec: _ => /[A-Za-z_][A-Za-z0-9_]*:[A-Za-z0-9_./-]+/,
    type_identifier: _ => /[A-Z][A-Za-z0-9_]*/,
    string: _ => token(choice(
      seq('"""', repeat(choice(/[^"]+/, /"[^"]/, /""[^"]/)), '"""'),
      seq('"', repeat(choice(/[^"\\]/, /\\./)), '"'),
    )),
    color_string: _ => /c"([^"\\]|\\.)*"/,
    block_text: _ => token(seq("<<", /([^>]|>[^>])*/, ">>")),
    line_text: _ => token.immediate(/[ \t][^\n]+/),
    number: _ => /\d+(\.\d+)?/,
    boolean: _ => choice("true", "false"),
    comment: _ => token(choice(/;;[^\n]*/, /\/\/[^\n]*/, /#[^\n]*/)),
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
