const visibleDiagnosticLimit = 4;

export function buildFailureMessage(snapshot) {
  if (!snapshot?.stale) return null;
  const diagnostics = snapshot.build_diagnostics || [];
  const lines = [
    snapshot.snapshot_id
      ? "Build failed. The preview is showing the last successful result."
      : "Build failed. No preview is available yet.",
  ];
  for (const diagnostic of diagnostics.slice(0, visibleDiagnosticLimit)) {
    lines.push(formatDiagnostic(diagnostic));
  }
  if (diagnostics.length > visibleDiagnosticLimit) {
    const remaining = diagnostics.length - visibleDiagnosticLimit;
    lines.push(`${remaining} more ${remaining === 1 ? "error" : "errors"}.`);
  }
  return lines.join("\n");
}

export function reconciliationFailureMessage(outcomes) {
  const messages = outcomes
    .filter((outcome) => outcome?.status === "failed")
    .map((outcome) => outcome.message ||
      "The pending source edit could not be reconciled with the rebuilt preview.");
  return combineFailureMessages(...messages);
}

export function combineFailureMessages(...messages) {
  const unique = [...new Set(messages.filter(Boolean))];
  return unique.length > 0 ? unique.join("\n") : null;
}

function formatDiagnostic(diagnostic) {
  const location = diagnosticLocation(diagnostic);
  const code = diagnostic.code ? ` [${diagnostic.code}]` : "";
  const message = String(diagnostic.message || "Unknown build error.")
    .trim()
    .replace(/\s+/g, " ");
  return `${location}${code} ${message}`;
}

function diagnosticLocation(diagnostic) {
  const file = fileLabel(diagnostic.uri);
  const start = diagnostic.range?.start;
  if (!Number.isSafeInteger(start?.line)) return file;
  const line = start.line + 1;
  const column = Number.isSafeInteger(start.character)
    ? `:${start.character + 1}`
    : "";
  return `${file}:${line}${column}`;
}

function fileLabel(uri) {
  if (!uri) return "document";
  try {
    const parsed = new URL(uri);
    const parts = decodeURIComponent(parsed.pathname).split("/").filter(Boolean);
    return parts.at(-1) || parsed.hostname || "document";
  } catch {
    const parts = String(uri).split(/[\\/]/).filter(Boolean);
    return parts.at(-1) || "document";
  }
}
