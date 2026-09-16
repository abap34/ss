#include "tree_sitter/parser.h"

enum TokenType { COMPOSITION_NEWLINE };

void *tree_sitter_ss_external_scanner_create(void) { return NULL; }
void tree_sitter_ss_external_scanner_destroy(void *payload) { (void)payload; }
unsigned tree_sitter_ss_external_scanner_serialize(void *payload, char *buffer) {
  (void)payload;
  (void)buffer;
  return 0;
}
void tree_sitter_ss_external_scanner_deserialize(void *payload, const char *buffer, unsigned length) {
  (void)payload;
  (void)buffer;
  (void)length;
}

bool tree_sitter_ss_external_scanner_scan(void *payload, TSLexer *lexer, const bool *valid_symbols) {
  (void)payload;
  if (!valid_symbols[COMPOSITION_NEWLINE]) return false;
  while (lexer->lookahead == ' ' || lexer->lookahead == '\t' || lexer->lookahead == '\r') {
    lexer->advance(lexer, true);
  }
  if (lexer->lookahead != '\n') return false;
  lexer->advance(lexer, false);
  lexer->mark_end(lexer);

  // Look through trivia, but consume only this newline. Comments remain
  // ordinary named tokens, and a following statement keeps its terminator.
  for (;;) {
    switch (lexer->lookahead) {
      case ' ': case '\t': case '\r': case '\n':
        lexer->advance(lexer, false);
        continue;
      case ';':
        lexer->advance(lexer, false);
        if (lexer->lookahead != ';') return false;
        break;
      case '#':
        break;
      default:
        goto operator;
    }
    while (!lexer->eof(lexer) && lexer->lookahead != '\n') lexer->advance(lexer, false);
  }

operator:;
  const int32_t first = lexer->lookahead;
  if (first != '|' && first != '/') return false;
  lexer->advance(lexer, false);
  if (lexer->lookahead == '=') lexer->advance(lexer, false);
  if (lexer->lookahead != first) return false;
  lexer->result_symbol = COMPOSITION_NEWLINE;
  return true;
}
