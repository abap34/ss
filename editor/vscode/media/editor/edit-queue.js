import { combineFailureMessages } from "./diagnostics.js";

// The queue owns request attempts. Feature policies own target resolution,
// coalescing, previews, and selection after a source edit becomes visible.
/**
 * @template {import("./edit-types.js").EditIntent} Intent
 * @template {import("./edit-types.js").Applied} Outcome
 */
export class EditQueue {
  /** @param {import("./edit-types.js").QueuePolicy<Intent, Outcome>} policy */
  constructor(policy) {
    this.policy = policy;
    /** @type {Intent | null} */
    this.pending = null;
    /** @type {Intent[]} */
    this.followups = [];
  }

  isBusy() {
    return this.pending != null || this.followups.length > 0;
  }

  intents() {
    return this.pending ? [this.pending, ...this.followups] : this.followups;
  }

  /** @param {Intent} intent */
  enqueue(intent) {
    intent.phase = "queued";
    if (this.pending) {
      const sameSlot = this.policy.sameSlot;
      if (this.pending.phase === "queued" && sameSlot?.(this.pending, intent)) {
        this.pending = intent;
      } else {
        const replace = sameSlot
          ? this.followups.findIndex((candidate) => sameSlot(candidate, intent))
          : -1;
        if (replace >= 0) this.followups[replace] = intent;
        else this.followups.push(intent);
      }
    } else {
      this.pending = intent;
      const snapshot = this.policy.snapshot();
      if (snapshot && !snapshot.stale) this.send(intent, snapshot);
    }
    this.policy.render();
    return true;
  }

  /** @param {import("./edit-types.js").EditResult} message */
  acceptResult(message) {
    const pending = this.pending;
    if (!pending || pending.phase !== "requested" ||
        message.requestId !== pending.message.requestId) return null;
    if (message.status === "applied") {
      pending.phase = "applied";
      pending.documentVersion = message.documentVersion;
      if (message.selection) pending.selection = message.selection;
      return null;
    }
    if (message.status === "stale") {
      pending.phase = "queued";
      return null;
    }
    const failure = this.fail(
      message.message || this.policy.failureMessage,
      this.policy.snapshot(),
    );
    this.policy.render();
    return failure;
  }

  /** @param {import("./edit-types.js").Snapshot} snapshot
   * @param {number} [documentVersion] */
  reconcile(snapshot, documentVersion) {
    const pending = this.pending;
    if (!pending || snapshot.stale) return null;
    if (pending.phase === "queued") {
      const failure = this.policy.rebase(snapshot, pending);
      if (failure) return this.fail(failure.message, snapshot);
      this.send(pending, snapshot);
      return null;
    }
    if (pending.phase !== "applied" ||
        snapshot.snapshot_id === pending.message.snapshotId ||
        (documentVersion != null && pending.documentVersion != null &&
          documentVersion < pending.documentVersion)) return null;
    const outcome = this.policy.applied(snapshot, pending, documentVersion);
    if (!outcome) return null;
    if (outcome.status === "failed") return this.fail(outcome.message, snapshot);
    this.discardPending();
    return this.promote(snapshot) || outcome;
  }

  /** @param {(intent: Intent) => boolean} predicate */
  cancelNewestQueued(predicate) {
    const index = this.followups.findLastIndex(predicate);
    if (index >= 0) {
      this.followups.splice(index, 1);
      this.policy.render();
      return true;
    }
    if (this.pending?.phase !== "queued" || !predicate(this.pending)) return false;
    this.discardPending();
    this.promote(this.policy.snapshot());
    this.policy.render();
    return true;
  }

  /** @param {(intent: Intent) => boolean} predicate */
  cancelWhere(predicate) {
    const previousLength = this.followups.length;
    this.followups = this.followups.filter((intent) => !predicate(intent));
    let changed = this.followups.length !== previousLength;
    if (this.pending && predicate(this.pending)) {
      this.discardPending();
      changed = true;
      this.promote(this.policy.snapshot());
    }
    return changed;
  }

  /** @param {Intent} intent
   * @param {import("./edit-types.js").Snapshot} snapshot */
  send(intent, snapshot) {
    intent.message.snapshotId = snapshot.snapshot_id;
    intent.message.requestId = this.policy.nextRequestId();
    intent.phase = "requested";
    this.policy.post(intent.message);
  }

  discardPending() {
    const pending = this.pending;
    this.pending = null;
    if (pending) this.policy.discard(pending);
  }

  /** @param {string} message
   * @param {import("./edit-types.js").Snapshot | null} snapshot
   * @returns {import("./edit-types.js").Failure} */
  fail(message, snapshot) {
    this.discardPending();
    return {
      status: "failed",
      message: combineFailureMessages(message, this.promote(snapshot)?.message) || message,
    };
  }

  /** @param {import("./edit-types.js").Snapshot | null} snapshot
   * @returns {import("./edit-types.js").Failure | null} */
  promote(snapshot) {
    let failureMessage = "";
    while (!this.pending && this.followups.length > 0) {
      const next = this.followups.shift();
      if (!next) break;
      this.pending = next;
      if (!snapshot || snapshot.stale) break;
      const invalid = this.policy.rebase(snapshot, next);
      if (invalid) {
        this.discardPending();
        failureMessage = combineFailureMessages(failureMessage, invalid.message) || invalid.message;
      } else {
        this.send(next, snapshot);
      }
    }
    return failureMessage ? { status: "failed", message: failureMessage } : null;
  }
}
