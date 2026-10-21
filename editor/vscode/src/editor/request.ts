import type { CancellationTokenSource, Disposable } from "vscode";

const requestCancelledErrorCode = -32800;
const contentModifiedErrorCode = -32801;
export const editorRequestTimeoutMs = 60_000;

// Cancellation must settle our wait even when the server never acknowledges it.
export function withRequestDeadline<T>(
  operation: () => PromiseLike<T>,
  cancellation: CancellationTokenSource,
  timeoutMs = editorRequestTimeoutMs,
): Promise<T> {
  let subscription: Disposable | undefined;
  let timer: ReturnType<typeof setTimeout> | undefined;
  const result = new Promise<T>((resolve, reject) => {
    const cancelled = () => reject(Object.assign(
      new Error("The editor request was cancelled."),
      { code: requestCancelledErrorCode },
    ));
    if (cancellation.token.isCancellationRequested) {
      cancelled();
      return;
    }
    subscription = cancellation.token.onCancellationRequested(cancelled);
    timer = setTimeout(() => {
      reject(new Error("The language server did not respond within 60 seconds. Use Restart WYSIWYG to recover."));
      cancellation.cancel();
    }, timeoutMs);
    Promise.resolve().then(() => {
      if (!cancellation.token.isCancellationRequested) return operation();
      throw Object.assign(new Error("The editor request was cancelled."), { code: requestCancelledErrorCode });
    }).then(resolve, reject);
  });
  return result.finally(() => {
    clearTimeout(timer);
    subscription?.dispose();
  });
}

export function isRetryableSnapshotError(error: unknown): boolean {
  if (typeof error !== "object" || error === null || !("code" in error)) {
    return false;
  }
  const code = (error as { code?: unknown }).code;
  return code === requestCancelledErrorCode || code === contentModifiedErrorCode;
}
