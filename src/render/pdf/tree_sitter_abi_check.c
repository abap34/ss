#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>

#include <tree_sitter/api.h>

const TSLanguage *tree_sitter_bash(void);
const TSLanguage *tree_sitter_c(void);
const TSLanguage *tree_sitter_cpp(void);
const TSLanguage *tree_sitter_css(void);
const TSLanguage *tree_sitter_go(void);
const TSLanguage *tree_sitter_html(void);
const TSLanguage *tree_sitter_java(void);
const TSLanguage *tree_sitter_javascript(void);
const TSLanguage *tree_sitter_json(void);
const TSLanguage *tree_sitter_julia(void);
const TSLanguage *tree_sitter_python(void);
const TSLanguage *tree_sitter_rust(void);
const TSLanguage *tree_sitter_toml(void);
const TSLanguage *tree_sitter_typescript(void);
const TSLanguage *tree_sitter_tsx(void);
const TSLanguage *tree_sitter_yaml(void);
const TSLanguage *tree_sitter_zig(void);

#if !defined(TREE_SITTER_LANGUAGE_VERSION)
#error tree-sitter headers do not expose TREE_SITTER_LANGUAGE_VERSION
#endif

#if !defined(TREE_SITTER_MIN_COMPATIBLE_LANGUAGE_VERSION)
#error tree-sitter headers do not expose TREE_SITTER_MIN_COMPATIBLE_LANGUAGE_VERSION
#endif

#if TREE_SITTER_MIN_COMPATIBLE_LANGUAGE_VERSION > TREE_SITTER_LANGUAGE_VERSION
#error tree-sitter headers expose an invalid ABI range
#endif

static int trace_enabled(void) {
  const char *value = getenv("SS_TREE_SITTER_CHECK_TRACE");
  return value != NULL && value[0] != '\0';
}

static int check_language(TSParser *parser, const char *name, const TSLanguage *language, const char *sample) {
  if (trace_enabled()) {
    fprintf(stderr, "checking tree-sitter %s\n", name);
    fflush(stderr);
  }
  uint32_t abi = ts_language_abi_version(language);
  if (
    abi < TREE_SITTER_MIN_COMPATIBLE_LANGUAGE_VERSION ||
    abi > TREE_SITTER_LANGUAGE_VERSION
  ) {
    fprintf(stderr, "tree-sitter %s parser ABI %u is outside runtime range %u..%u\n",
      name,
      abi,
      (unsigned)TREE_SITTER_MIN_COMPATIBLE_LANGUAGE_VERSION,
      (unsigned)TREE_SITTER_LANGUAGE_VERSION);
    return 1;
  }
  if (!ts_parser_set_language(parser, language)) {
    fprintf(stderr, "linked tree-sitter runtime rejected %s parser ABI %u\n", name, abi);
    fprintf(stderr, "header accepts tree-sitter ABI range %u..%u\n",
      (unsigned)TREE_SITTER_MIN_COMPATIBLE_LANGUAGE_VERSION,
      (unsigned)TREE_SITTER_LANGUAGE_VERSION);
    return 1;
  }
  TSTree *tree = ts_parser_parse_string(parser, NULL, sample, (uint32_t)strlen(sample));
  if (tree == NULL) {
    fprintf(stderr, "tree-sitter %s parser failed to parse the build sample\n", name);
    return 1;
  }
  ts_tree_delete(tree);
  return 0;
}

int main(void) {
  TSParser *parser = ts_parser_new();
  if (parser == NULL) {
    fprintf(stderr, "failed to create tree-sitter parser\n");
    return 1;
  }

  int status = 0;
  status |= check_language(parser, "bash", tree_sitter_bash(), "echo \"$HOME\"\n");
  status |= check_language(parser, "c", tree_sitter_c(), "#include <stdio.h>\nint main(void) { return 0; }\n");
  status |= check_language(parser, "cpp", tree_sitter_cpp(), "class Sample { public: auto method() { return nullptr; } };\n");
  status |= check_language(parser, "css", tree_sitter_css(), "body { color: red; }\n");
  status |= check_language(parser, "go", tree_sitter_go(), "package main\nfunc main() { println(\"hello\") }\n");
  status |= check_language(parser, "html", tree_sitter_html(), "<!doctype html><p class=\"sample\">hello</p>\n");
  status |= check_language(parser, "java", tree_sitter_java(), "class Main { public static void main(String[] args) { System.out.println(\"hello\"); } }\n");
  status |= check_language(parser, "javascript", tree_sitter_javascript(), "function main() { return 1; }\n");
  status |= check_language(parser, "json", tree_sitter_json(), "{\"name\": true, \"count\": 1}\n");
  status |= check_language(parser, "julia", tree_sitter_julia(), "function f(x)\n  x + 1\nend\n");
  status |= check_language(parser, "python", tree_sitter_python(), "def f(x):\n    return x + 1\n");
  status |= check_language(parser, "rust", tree_sitter_rust(), "fn main() { let value = 1; }\n");
  status |= check_language(parser, "toml", tree_sitter_toml(), "name = \"ss\"\ncount = 1\n");
  status |= check_language(parser, "typescript", tree_sitter_typescript(), "const value: number = 1;\n");
  status |= check_language(parser, "tsx", tree_sitter_tsx(), "const value = <div>{1}</div>;\n");
  status |= check_language(parser, "yaml", tree_sitter_yaml(), "name: ss\nitems:\n  - one\n");
  status |= check_language(parser, "zig", tree_sitter_zig(), "pub fn main() void { const value = 1; }\n");
  ts_parser_delete(parser);
  return status;
}
