import { editingTargetByBinding, editingTargetByNode } from "./editing-target.js";

export class EditorNavigation {
  constructor(state) {
    this.state = state;
    this.viewportPosition = null;
    this.pendingPageReveal = null;
  }

  requestPageReveal(message) {
    if (!Number.isSafeInteger(message.revision) || message.revision < this.state.revision) return;
    this.pendingPageReveal = message;
  }

  takePageReveal() {
    const target = this.pendingPageReveal;
    if (!target || !this.state.snapshot || target.revision > this.state.revision) return null;
    this.pendingPageReveal = null;
    return target.snapshotId === this.state.snapshot.snapshot_id && this.hasPage(target.pageId)
      ? target.pageId
      : null;
  }

  reconcile(snapshot, previousSnapshot = null) {
    const pages = snapshot.layout.pages || [];
    const objects = snapshot.layout.objects || [];
    const previousTarget = editingTargetByNode(previousSnapshot, this.state.selectedObjectId);
    if (previousTarget) {
      const target = editingTargetByBinding(snapshot, previousTarget.page_id, previousTarget.binding);
      this.state.selectedObjectId = target?.node_id ?? null;
    }
    const selected = objects.find((object) =>
      object.id === this.state.selectedObjectId
    );
    if (!selected) this.state.selectedObjectId = null;
    if (!pages.some((page) => page.id === this.state.currentPageId)) {
      this.state.currentPageId = selected?.page_id ?? pages[0]?.id ?? null;
    }
  }

  selectPage(pageId) {
    if (!this.hasPage(pageId)) return false;
    this.state.currentPageId = pageId;
    return true;
  }

  selectObject(objectId, pageId) {
    const object = this.state.snapshot?.layout.objects.find((candidate) =>
      candidate.id === objectId
    );
    if (!object || object.page_id !== pageId || !this.hasPage(pageId)) {
      return { selected: false, pageChanged: false };
    }
    const pageChanged = this.state.currentPageId !== pageId;
    this.state.selectedObjectId = objectId;
    this.state.currentPageId = pageId;
    return { selected: true, pageChanged };
  }

  rememberViewport(viewport) {
    this.viewportPosition = viewport
      ? { left: viewport.scrollLeft, top: viewport.scrollTop }
      : null;
  }

  restoreViewport(viewport) {
    if (!viewport || !this.viewportPosition) return;
    viewport.scrollLeft = this.viewportPosition.left;
    viewport.scrollTop = this.viewportPosition.top;
  }

  hasPage(pageId) {
    return Boolean(
      this.state.snapshot?.layout.pages.some((page) => page.id === pageId),
    );
  }
}
