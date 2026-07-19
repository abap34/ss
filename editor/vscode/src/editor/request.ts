const requestCancelledErrorCode = -32800;
const contentModifiedErrorCode = -32801;

export function isRetryableSnapshotError(error: unknown): boolean {
  if (typeof error !== "object" || error === null || !("code" in error)) {
    return false;
  }
  const code = (error as { code?: unknown }).code;
  return code === requestCancelledErrorCode || code === contentModifiedErrorCode;
}
