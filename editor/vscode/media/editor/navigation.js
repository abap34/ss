export class EditorNavigation {
  constructor(state) {
    this.state = state;
    this.viewportPosition = null;
  }

  reconcile(snapshot) {
    const pages = snapshot.layout.pages || [];
    const objects = snapshot.layout.objects || [];
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
    if (this.state.mode === "single") this.state.selectedObjectId = null;
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
