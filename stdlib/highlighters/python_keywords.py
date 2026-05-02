#!/usr/bin/env python3
from __future__ import annotations

import argparse
import io
import json
import keyword
import re
import sys
import tokenize
from collections.abc import Sequence


def main(argv: Sequence[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--language", default="python")
    args = parser.parse_args(argv[1:])

    if args.language != "python":
        raise SystemExit(f"unsupported language: {args.language}")

    source = sys.stdin.read()
    payload = {
        "schema": "ss.highlight.v1",
        "language": args.language,
        "lines": highlight_python(source),
    }
    json.dump(payload, sys.stdout, ensure_ascii=False)
    return 0


def highlight_python(source: str) -> list[list[dict]]:
    try:
        return tokenize_highlight(source)
    except (tokenize.TokenError, IndentationError):
        return regex_fallback(source)


def tokenize_highlight(source: str) -> list[list[dict]]:
    offsets = line_offsets(source)
    lines: list[list[dict]] = [[]]
    cursor = 0

    for tok in tokenize.generate_tokens(io.StringIO(source).readline):
        if tok.type == tokenize.ENDMARKER:
            break
        start = absolute_index(offsets, tok.start)
        end = absolute_index(offsets, tok.end)
        if cursor < start:
            append_text(lines, source[cursor:start], "plain")
        token_class = "keyword" if tok.type == tokenize.NAME and keyword.iskeyword(tok.string) else "plain"
        append_text(lines, tok.string, token_class)
        cursor = end

    if cursor < len(source):
        append_text(lines, source[cursor:], "plain")

    if source.endswith("\n") and lines and not lines[-1]:
        lines.pop()
    return lines or [[]]


_IDENT_RE = re.compile(r"\b[A-Za-z_][A-Za-z0-9_]*\b")


def regex_fallback(source: str) -> list[list[dict]]:
    lines: list[list[dict]] = [[]]
    cursor = 0
    for match in _IDENT_RE.finditer(source):
        start, end = match.span()
        if cursor < start:
            append_text(lines, source[cursor:start], "plain")
        token = match.group(0)
        token_class = "keyword" if keyword.iskeyword(token) else "plain"
        append_text(lines, token, token_class)
        cursor = end
    if cursor < len(source):
        append_text(lines, source[cursor:], "plain")
    if source.endswith("\n") and lines and not lines[-1]:
        lines.pop()
    return lines or [[]]


def line_offsets(source: str) -> list[int]:
    offsets = [0]
    total = 0
    for line in source.splitlines(keepends=True):
        total += len(line)
        offsets.append(total)
    return offsets


def absolute_index(offsets: Sequence[int], position: tuple[int, int]) -> int:
    row, col = position
    if row <= 0:
        return col
    if row - 1 >= len(offsets):
        return offsets[-1] + col
    return offsets[row - 1] + col


def append_text(lines: list[list[dict]], text: str, token_class: str) -> None:
    parts = text.split("\n")
    for index, part in enumerate(parts):
        if part:
            if lines[-1] and lines[-1][-1]["class"] == token_class:
                lines[-1][-1]["text"] += part
            else:
                lines[-1].append({"text": part, "class": token_class})
        if index < len(parts) - 1:
            lines.append([])


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
