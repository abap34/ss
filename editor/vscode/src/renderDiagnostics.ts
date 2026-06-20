import * as path from "path";

export type ParsedSsDiagnosticSeverity = "error" | "warning";

export interface ParsedSsDiagnostic {
  filePath: string;
  line: number;
  character: number;
  code: string;
  severity: ParsedSsDiagnosticSeverity;
  message: string;
}

const diagnosticHeaderPattern = /^(ERROR|WARNING): (.*):(\d+):(\d+): ([A-Za-z_][A-Za-z0-9_]*): ?(.*)$/;
const maxDiagnosticMessageLength = 4000;

export function parseSsDiagnostics(output: string, pathMap: Record<string, string>): ParsedSsDiagnostic[] {
  const diagnostics: ParsedSsDiagnostic[] = [];
  const lines = stripAnsi(output).replace(/\r/g, "\n").split("\n");
  for (let index = 0; index < lines.length; index += 1) {
    const match = diagnosticHeaderPattern.exec(lines[index]);
    if (!match) {
      continue;
    }
    const [, severityText, rawPath, lineText, characterText, code, firstLine] = match;
    diagnostics.push({
      filePath: resolveDiagnosticPath(rawPath, pathMap),
      line: Math.max(Number.parseInt(lineText, 10) - 1, 0),
      character: Math.max(Number.parseInt(characterText, 10) - 1, 0),
      code,
      severity: severityText === "WARNING" ? "warning" : "error",
      message: collectDiagnosticMessage(lines, index + 1, firstLine),
    });
  }
  return diagnostics;
}

export function fallbackSsDiagnosticMessage(output: string, exitCode: number | null): string {
  const trimmed = stripAnsi(output).trim();
  if (trimmed.length > 0) {
    return truncateDiagnosticMessage(trimmed);
  }
  return `render failed with exit code ${exitCode ?? "unknown"}`;
}

function resolveDiagnosticPath(filePath: string, pathMap: Record<string, string>): string {
  const normalized = path.isAbsolute(filePath) ? normalizePath(filePath) : filePath;
  return pathMap[normalized] ?? pathMap[normalizePath(filePath)] ?? filePath;
}

function normalizePath(filePath: string): string {
  return path.resolve(filePath);
}

function collectDiagnosticMessage(lines: string[], startIndex: number, firstLine: string): string {
  const details: string[] = [];
  for (let index = startIndex; index < lines.length; index += 1) {
    const line = lines[index];
    if (diagnosticHeaderPattern.test(line) || sourceExcerptLine(line)) {
      break;
    }
    const trimmed = line.trimEnd();
    if (trimmed.length > 0) {
      details.push(trimmed);
    }
  }
  const message = details.length === 0 ? firstLine : `${firstLine}\n${details.join("\n")}`;
  return truncateDiagnosticMessage(message);
}

function sourceExcerptLine(line: string): boolean {
  return /^\s*\d+\s+\|/.test(line) || /^\s*\|\s+/.test(line);
}

function truncateDiagnosticMessage(message: string): string {
  if (message.length <= maxDiagnosticMessageLength) {
    return message;
  }
  return `${message.slice(0, maxDiagnosticMessageLength - 3)}...`;
}

function stripAnsi(text: string): string {
  return text.replace(/\x1b\[[0-?]*[ -/]*[@-~]/g, "");
}
