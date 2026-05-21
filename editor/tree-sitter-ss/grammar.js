const PREC = {
  call: 8,
  unary: 7,
  mul: 6,
  add: 5,
  compare: 4,
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

    parameters: $ => seq("(", optional(commaSep($.parameter)), ")"),
    parameter: $ => seq(field("name", $.identifier), ":", field("type", $.type), optional(seq("=", $._expression))),
    effect_clause: $ => seq("!", $.identifier, repeat(seq("|", $.identifier))),

    type_declaration: $ => seq(
      "type",
      field("name", $.type_identifier),
      "=",
      choice($.type, $.object_type),
    ),

    object_type: $ => seq(
      choice("object", "protocol"),
      optional(seq("extends", $.type_identifier)),
      "{",
      repeat($._terminator),
      repeat($.object_field),
      "}",
    ),

    object_extension: $ => seq(
      "extend",
      field("target", $.type_identifier),
      optional(seq("implements", $.type_identifier)),
      "{",
      repeat($._terminator),
      repeat($.object_field),
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
      $.property_statement,
      $.if_statement,
      $.for_statement,
      $.block_call_statement,
      $.expression_statement,
      $.line_call_statement,
    ),

    let_statement: $ => seq("let", field("name", $.identifier), "=", field("value", $._expression), $._terminator),
    return_statement: $ => seq("return", field("value", $._expression), $._terminator),
    constrain_statement: $ => seq(optional("constrain"), field("left", $._expression), "==", field("right", $._expression), optional(seq(choice("+", "-"), $._expression)), $._terminator),
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

    block_call_statement: $ => seq(field("function", $.identifier), field("text", $.block_text), optional($._terminator)),
    line_call_statement: $ => seq(field("function", $.identifier), field("text", $.line_text), $._terminator),
    expression_statement: $ => seq($._expression, $._terminator),

    _expression: $ => choice(
      $.binary_expression,
      $.unary_expression,
      $.call_expression,
      $.member_expression,
      $.if_expression,
      $.identifier,
      $.string,
      $.color_string,
      $.number,
      $.boolean,
      $.block_text,
      seq("(", $._expression, ")"),
    ),

    binary_expression: $ => choice(
      prec.left(PREC.mul, seq($._expression, choice("*", "/"), $._expression)),
      prec.left(PREC.add, seq($._expression, choice("+", "-"), $._expression)),
    ),

    unary_expression: $ => prec(PREC.unary, seq("-", $._expression)),
    call_expression: $ => prec(PREC.call, seq(
      field("function", $.identifier),
      "(",
      repeat($._terminator),
      optional(commaSepNewline($, $._expression)),
      repeat($._terminator),
      ")",
    )),
    member_expression: $ => prec(PREC.call, seq(field("object", choice($.identifier, $.page)), ".", field("member", $.identifier))),
    if_expression: $ => seq("if", field("condition", $._expression), "then", field("then", $._expression), "else", field("else", $._expression), "end"),

    annotation: $ => seq("@", field("name", $.identifier), optional(seq("(", optional(commaSep($._expression)), ")"))),

    type: $ => choice(
      "document",
      "page",
      "object",
      "selection",
      "anchor",
      "function",
      "style",
      "string",
      "number",
      "bool",
      "boolean",
      "constraints",
      "fragment",
      "code",
      seq("list", "<", $.type, ">"),
      $.type_identifier,
    ),

    identifier: _ => /[A-Za-z_][A-Za-z0-9_]*/,
    import_spec: _ => /[A-Za-z_][A-Za-z0-9_]*:[A-Za-z0-9_./-]+/,
    type_identifier: _ => /[A-Z][A-Za-z0-9_]*/,
    page: _ => "page",
    string: _ => /"([^"\\]|\\.)*"/,
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
