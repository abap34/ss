export class RenderQueue {
  constructor(limit) {
    this.limit = limit;
    this.active = 0;
    this.serial = 0;
    this.pending = [];
    this.running = new Set();
    this.drainTimer = null;
    this.closed = false;
    this.closePromise = null;
    this.resolveClose = null;
  }

  enqueue(priority, body, signal) {
    if (this.closed) return Promise.reject(new Error("PDF render queue was disposed"));
    if (signal?.aborted) return Promise.resolve();
    return new Promise((resolve, reject) => {
      const item = {
        priority,
        serial: this.serial++,
        body,
        resolve,
        reject,
        signal,
        controller: new AbortController(),
        state: "pending",
        onAbort: null,
      };
      item.onAbort = () => {
        this.cancel(item);
      };
      signal?.addEventListener("abort", item.onAbort, { once: true });
      this.pending.push(item);
      this.pending.sort((left, right) =>
        right.priority - left.priority || left.serial - right.serial
      );
      this.scheduleDrain();
    });
  }

  close() {
    if (this.closePromise) return this.closePromise;
    this.closed = true;
    this.closePromise = new Promise((resolve) => {
      this.resolveClose = resolve;
    });
    if (this.drainTimer !== null) clearTimeout(this.drainTimer);
    this.drainTimer = null;
    for (const item of [...this.pending]) this.cancel(item);
    for (const item of this.running) item.controller.abort();
    this.finishClose();
    return this.closePromise;
  }

  scheduleDrain() {
    if (this.closed || this.drainTimer !== null) return;
    this.drainTimer = setTimeout(() => {
      this.drainTimer = null;
      this.drain();
    }, 0);
  }

  drain() {
    if (this.closed) return;
    while (this.active < this.limit && this.pending.length > 0) {
      const item = this.pending.shift();
      if (item.state !== "pending") continue;
      item.state = "active";
      this.active += 1;
      this.running.add(item);
      Promise.resolve()
        .then(() => item.body(item.controller.signal))
        .then(item.resolve, item.reject)
        .finally(() => {
          item.state = "complete";
          item.signal?.removeEventListener("abort", item.onAbort);
          this.running.delete(item);
          this.active -= 1;
          if (this.closed) this.finishClose();
          else this.drain();
        });
    }
  }

  cancel(item) {
    item.controller.abort();
    if (item.state !== "pending") return;
    const index = this.pending.indexOf(item);
    if (index >= 0) this.pending.splice(index, 1);
    item.state = "cancelled";
    item.signal?.removeEventListener("abort", item.onAbort);
    item.resolve();
  }

  finishClose() {
    if (!this.closed || this.active !== 0 || !this.resolveClose) return;
    const resolve = this.resolveClose;
    this.resolveClose = null;
    resolve();
  }
}

export const aborted = Symbol("PDF operation aborted");

export function waitForAbort(value, signal) {
  if (!signal) return Promise.resolve(value);
  if (signal.aborted) return Promise.resolve(aborted);
  return new Promise((resolve, reject) => {
    const onAbort = () => {
      signal.removeEventListener("abort", onAbort);
      resolve(aborted);
    };
    signal.addEventListener("abort", onAbort, { once: true });
    Promise.resolve(value).then(
      (result) => {
        signal.removeEventListener("abort", onAbort);
        resolve(result);
      },
      (error) => {
        signal.removeEventListener("abort", onAbort);
        reject(error);
      },
    );
  });
}
