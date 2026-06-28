import * as path from "path";

export type ParsedSsDiagnosticSeverity = "error" | "warning";

export interface ParsedSsDiagnostic {
  filePath: string;
  line: number;
  character: number;
  endLine: number;
  endCharacter: number;
  code: string;
  severity: ParsedSsDiagnosticSeverity;
  message: string;
}

const maxDiagnosticMessageLength = 4000;

export function parseSsDiagnosticsJson(source: string, pathMap: Record<string, string>): ParsedSsDiagnostic[] {
  const payload = JSON.parse(source) as unknown;
  if (!isObject(payload) || payload.schema !== 1 || !Array.isArray(payload.diagnostics)) {
    return [];
  }

  const diagnostics: ParsedSsDiagnostic[] = [];
  for (const item of payload.diagnostics) {
    if (!isObject(item)) {
      continue;
    }
    const filePath = stringField(item, "path");
    const message = stringField(item, "message");
    if (!filePath || !message) {
      continue;
    }
    const start = positionField(item, "range", "start");
    const end = positionField(item, "range", "end");
    if (!start || !end) {
      continue;
    }
    diagnostics.push({
      filePath: resolveDiagnosticPath(filePath, pathMap),
      line: Math.max(start.line, 0),
      character: Math.max(start.character, 0),
      endLine: Math.max(end.line, start.line),
      endCharacter: Math.max(end.character, start.character + 1),
      code: stringField(item, "code") ?? "RenderFailed",
      severity: stringField(item, "severity") === "warning" ? "warning" : "error",
      message: truncateDiagnosticMessage(message),
    });
  }
  return diagnostics;
}

function positionField(
  item: Record<string, unknown>,
  rangeKey: string,
  positionKey: string,
): { line: number; character: number } | undefined {
  const range = item[rangeKey];
  if (!isObject(range)) {
    return undefined;
  }
  const position = range[positionKey];
  if (!isObject(position)) {
    return undefined;
  }
  const line = numberField(position, "line");
  const character = numberField(position, "character");
  if (line === undefined || character === undefined) {
    return undefined;
  }
  return { line, character };
}

function stringField(item: Record<string, unknown>, key: string): string | undefined {
  const value = item[key];
  return typeof value === "string" ? value : undefined;
}

function numberField(item: Record<string, unknown>, key: string): number | undefined {
  const value = item[key];
  return typeof value === "number" && Number.isFinite(value) ? Math.trunc(value) : undefined;
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function resolveDiagnosticPath(filePath: string, pathMap: Record<string, string>): string {
  const normalized = path.isAbsolute(filePath) ? normalizePath(filePath) : filePath;
  return pathMap[normalized] ?? pathMap[normalizePath(filePath)] ?? filePath;
}

function normalizePath(filePath: string): string {
  return path.resolve(filePath);
}

function truncateDiagnosticMessage(message: string): string {
  if (message.length <= maxDiagnosticMessageLength) {
    return message;
  }
  return `${message.slice(0, maxDiagnosticMessageLength - 3)}...`;
}
