export interface RefreshTiming {
  pendingSinceMs: number;
  delayMs: number;
}

export function shouldStartPendingRefresh(
  refreshPending: boolean,
  timerPending: boolean,
): boolean {
  return refreshPending && !timerPending;
}

export function refreshTiming(
  nowMs: number,
  pendingSinceMs: number | undefined,
  debounceMs: number,
  maxWaitMs: number,
): RefreshTiming {
  const pendingSince = pendingSinceMs ?? nowMs;
  const trailingDeadline = nowMs + nonNegative(debounceMs);
  const maximumDeadline = pendingSince + nonNegative(maxWaitMs);
  return {
    pendingSinceMs: pendingSince,
    delayMs: Math.max(0, Math.min(trailingDeadline, maximumDeadline) - nowMs),
  };
}

function nonNegative(value: number): number {
  return Number.isFinite(value) ? Math.max(0, value) : 0;
}
