(function () {
  "use strict";

  const vscode = acquireVsCodeApi();
  const pagesElement = document.getElementById("pages");
  const statusElement = document.getElementById("status");
  const editModeElement = document.getElementById("editMode");
  const refreshButton = document.getElementById("refresh");
  const showLogButton = document.getElementById("showLog");
  const zoomOut = document.getElementById("zoomOut");
  const fitWidth = document.getElementById("fitWidth");
  const zoomIn = document.getElementById("zoomIn");
  const zoomValue = document.getElementById("zoomValue");
  const svgNamespace = "http://www.w3.org/2000/svg";
  const minScale = 0.2;
  const maxScale = 4;
  const fitWidthInset = 64;

  let snapshot = undefined;
  let drag = undefined;
  let renderToken = 0;
  let resizeTimer = undefined;
  let useFitWidth = true;
  let scale = 1;
  let lastRenderedScale = 1;
  let displayPagesByPageId = new Map();
  let displayPagesByIndex = new Map();
  let objectsByPageId = new Map();
  let objectsById = new Map();
  let resourcesById = new Map();
  let relationsByPageId = new Map();
  let selectedObjectId = undefined;
  let shiftDown = false;
  let nextGestureRequestId = 1;
  const pendingGestures = new Map();

  window.addEventListener("message", (event) => {
    const message = event.data;
    if (!message || typeof message !== "object") {
      return;
    }
    if (message.type === "snapshot") {
      snapshot = message.snapshot;
      rebuildSnapshotIndexes();
      const displayPages = snapshot.display && snapshot.display.pages ? snapshot.display.pages.length : 0;
      const displayItems = snapshot.display && snapshot.display.pages ? snapshot.display.pages.reduce((sum, page) => sum + (page.items || []).length, 0) : 0;
      reportLog("snapshot pages=" + (snapshot.pages || []).length + " objects=" + (snapshot.objects || []).length + " displayPages=" + displayPages + " displayItems=" + displayItems + " diagnostics=" + (snapshot.diagnostics || []).length);
      renderCurrent(captureView());
      return;
    }
    if (message.type === "status") {
      setStatus(message.message || "");
    }
    if (message.type === "layout-edit-result") {
      finishPendingGesture(message);
    }
  });

  window.addEventListener("resize", () => {
    if (!snapshot || !useFitWidth) {
      return;
    }
    if (resizeTimer) {
      clearTimeout(resizeTimer);
    }
    resizeTimer = setTimeout(() => {
      resizeTimer = undefined;
      renderCurrent(captureView());
    }, 120);
  });

  window.addEventListener("keydown", (event) => {
    if (event.key === "Shift") {
      setShiftDown(true);
    }
  });

  window.addEventListener("keyup", (event) => {
    if (event.key === "Shift") {
      setShiftDown(false);
    }
  });

  window.addEventListener("blur", () => {
    setShiftDown(false);
  });

  refreshButton.addEventListener("click", () => {
    vscode.postMessage({ type: "refresh" });
  });
  showLogButton.addEventListener("click", () => {
    vscode.postMessage({ type: "show-log" });
  });
  zoomOut.addEventListener("click", () => zoomBy(1 / 1.2));
  zoomIn.addEventListener("click", () => zoomBy(1.2));
  fitWidth.addEventListener("click", () => {
    useFitWidth = true;
    renderCurrent(captureView());
  });

  setControls(false);
  setEditMode(false);
  vscode.postMessage({ type: "ready" });
  reportLog("ready");

  function renderCurrent(previousView) {
    const token = renderToken + 1;
    renderToken = token;
    if (!snapshot) {
      setEmpty("No snapshot");
      setControls(false);
      return;
    }
    const pages = snapshot.pages || [];
    if (pages.length === 0) {
      setEmpty("No pages");
      setControls(false);
      return;
    }

    const firstWidth = pages[0].frame.width || 1280;
    const targetScale = useFitWidth ? fitScale(firstWidth) : scale;
    lastRenderedScale = targetScale;
    updateZoomValue();
    setControls(true);

    try {
      const renderedPages = pages.map((page) => renderPage(page, targetScale));
      if (token !== renderToken) {
        return;
      }
      pagesElement.replaceChildren(...renderedPages);
      restoreView(previousView);
      const diagnosticCount = snapshot.diagnostics ? snapshot.diagnostics.length : 0;
      setStatus(diagnosticCount > 0 ? diagnosticCount + " diagnostics" : "");
      reportLog("rendered pages=" + renderedPages.length + " scale=" + targetScale.toFixed(3) + " html=true");
    } catch (error) {
      reportError("render failed: " + errorMessage(error));
      setStatus("Failed to render preview");
    }
  }

  function rebuildSnapshotIndexes() {
    displayPagesByPageId = new Map();
    displayPagesByIndex = new Map();
    objectsByPageId = new Map();
    objectsById = new Map();
    resourcesById = new Map();
    relationsByPageId = new Map();

    const displayPages = snapshot && snapshot.display ? snapshot.display.pages || [] : [];
    for (const page of displayPages) {
      displayPagesByPageId.set(page.pageId, page);
      displayPagesByIndex.set(page.index, page);
    }

    for (const object of snapshot.objects || []) {
      objectsById.set(object.id, object);
      const pageObjects = objectsByPageId.get(object.pageId);
      if (pageObjects) {
        pageObjects.push(object);
      } else {
        objectsByPageId.set(object.pageId, [object]);
      }
    }

    const resources = snapshot && snapshot.display ? snapshot.display.resources || [] : [];
    for (const resource of resources) {
      resourcesById.set(resource.id, resource);
    }

    for (const relation of snapshot.relations || []) {
      const pageRelations = relationsByPageId.get(relation.pageId);
      if (pageRelations) {
        pageRelations.push(relation);
      } else {
        relationsByPageId.set(relation.pageId, [relation]);
      }
    }
  }

  function renderPage(page, targetScale) {
    const holder = document.createElement("section");
    holder.className = "page";
    holder.dataset.page = String(page.index);
    holder.style.width = Math.floor(page.frame.width * targetScale) + "px";

    const header = document.createElement("div");
    header.className = "pageHeader";
    header.textContent = page.label || "page " + page.index;
    holder.appendChild(header);

    const surface = document.createElement("div");
    surface.className = "pageSurface";
    surface.style.width = Math.floor(page.frame.width * targetScale) + "px";
    surface.style.height = Math.floor(page.frame.height * targetScale) + "px";
    holder.appendChild(surface);

    const displaySvg = document.createElementNS(svgNamespace, "svg");
    displaySvg.classList.add("pageDisplay");
    displaySvg.setAttribute("viewBox", "0 0 " + page.frame.width + " " + page.frame.height);
    displaySvg.setAttribute("width", String(page.frame.width));
    displaySvg.setAttribute("height", String(page.frame.height));
    surface.appendChild(displaySvg);

    const displayPage = displayPageFor(page);
    if (displayPage) {
      for (const item of displayPage.items || []) {
        const element = renderDisplayItem(item);
        if (element) {
          displaySvg.appendChild(element);
        }
      }
    }

    const overlaySvg = document.createElementNS(svgNamespace, "svg");
    overlaySvg.classList.add("pageOverlay");
    overlaySvg.setAttribute("viewBox", "0 0 " + page.frame.width + " " + page.frame.height);
    overlaySvg.setAttribute("width", String(page.frame.width));
    overlaySvg.setAttribute("height", String(page.frame.height));
    overlaySvg.dataset.pageId = String(page.id);
    surface.appendChild(overlaySvg);

    const relationsGroup = document.createElementNS(svgNamespace, "g");
    relationsGroup.classList.add("relations");
    overlaySvg.appendChild(relationsGroup);
    renderRelations(overlaySvg, page.id);

    for (const object of objectsForPage(page.id).slice().sort(objectHitOrder)) {
      overlaySvg.appendChild(renderObject(overlaySvg, object));
    }

    return holder;
  }

  function renderDisplayItem(item) {
    if (!item || typeof item !== "object") {
      return undefined;
    }
    if (item.type === "shape") {
      return renderShapeItem(item);
    }
    if (item.type === "text") {
      return renderTextItem(item);
    }
    if (item.type === "resource") {
      return renderResourceItem(item);
    }
    return undefined;
  }

  function renderShapeItem(item) {
    const rect = document.createElementNS(svgNamespace, "rect");
    rect.classList.add("displayShape");
    rect.setAttribute("x", String(item.frame.x));
    rect.setAttribute("y", String(item.frame.y));
    rect.setAttribute("width", String(Math.max(0, item.frame.width)));
    rect.setAttribute("height", String(Math.max(0, item.frame.height)));
    rect.setAttribute("rx", String(Math.max(0, item.radius || 0)));
    rect.setAttribute("ry", String(Math.max(0, item.radius || 0)));
    rect.setAttribute("fill", color(item.fill, "none"));
    rect.setAttribute("stroke", color(item.stroke, "none"));
    rect.setAttribute("stroke-width", String(Math.max(0, item.lineWidth || 0)));
    if (Array.isArray(item.dash)) {
      rect.setAttribute("stroke-dasharray", item.dash.join(" "));
    }
    return rect;
  }

  function renderTextItem(item) {
    const group = document.createElementNS(svgNamespace, "g");
    group.classList.add("displayTextGroup");
    if (!Array.isArray(item.lines)) {
      return renderLegacyTextItem(item);
    }
    for (const line of item.lines) {
      for (const span of line.spans || []) {
        if (span.kind === "glyphs") {
          const text = document.createElementNS(svgNamespace, "text");
          text.classList.add("displayGlyphs");
          text.textContent = span.text || "";
          text.setAttribute("x", String(item.frame.x + (span.x || 0)));
          text.setAttribute("y", String(line.baselineY || item.frame.y));
          text.setAttribute("fill", color(span.color, "#111111"));
          text.setAttribute("font-family", span.fontFamily || "Helvetica, Arial, sans-serif");
          text.setAttribute("font-size", String(Math.max(1, span.fontSize || 18)));
          text.setAttribute("font-style", span.fontStyle || "normal");
          text.setAttribute("font-weight", String(span.fontWeight || 400));
          if (span.strikethrough) {
            text.setAttribute("text-decoration", "line-through");
          }
          group.appendChild(text);
        } else if (span.kind === "resource") {
          const resource = resourceById(span.resourceId);
          if (resource && resource.uri) {
            const image = document.createElementNS(svgNamespace, "image");
            image.classList.add("displayInlineResource");
            image.setAttribute("x", String(item.frame.x + (span.x || 0)));
            image.setAttribute("y", String(item.frame.y + (span.y || 0)));
            image.setAttribute("width", String(Math.max(1, span.width || 1)));
            image.setAttribute("height", String(Math.max(1, span.height || 1)));
            setImageHref(image, resource);
            image.setAttribute("preserveAspectRatio", "xMidYMid meet");
            group.appendChild(image);
          } else {
            reportLog("inline resource missing uri id=" + span.resourceId);
          }
        }
      }
    }
    return group;
  }

  function renderLegacyTextItem(item) {
    const foreign = document.createElementNS(svgNamespace, "foreignObject");
    foreign.classList.add("displayTextForeign");
    foreign.setAttribute("x", String(item.frame.x));
    foreign.setAttribute("y", String(item.frame.y));
    foreign.setAttribute("width", String(Math.max(1, item.frame.width)));
    foreign.setAttribute("height", String(Math.max(1, item.frame.height)));
    const block = document.createElement("div");
    block.className = "displayText";
    block.textContent = item.text || "";
    block.style.color = color(item.color, "#111111");
    block.style.fontFamily = item.fontFamily || "Helvetica, Arial, sans-serif";
    block.style.fontSize = Math.max(1, item.fontSize || 18) + "px";
    block.style.fontStyle = item.fontStyle || "normal";
    block.style.fontWeight = String(item.fontWeight || "400");
    block.style.lineHeight = Math.max(1, item.lineHeight || item.fontSize || 18) + "px";
    block.style.whiteSpace = item.wrap === false ? "pre" : "pre-wrap";
    foreign.appendChild(block);
    return foreign;
  }

  function renderResourceItem(item) {
    const resource = resourceById(item.resourceId);
    if (!resource || !resource.uri) {
      reportLog("resource missing uri id=" + item.resourceId + " node=" + item.nodeId);
      return renderResourceFallback(item);
    }
    const image = document.createElementNS(svgNamespace, "image");
    image.classList.add("displayResource");
    image.setAttribute("x", String(item.frame.x));
    image.setAttribute("y", String(item.frame.y));
    image.setAttribute("width", String(Math.max(1, item.frame.width)));
    image.setAttribute("height", String(Math.max(1, item.frame.height)));
    setImageHref(image, resource);
    image.setAttribute("preserveAspectRatio", "xMidYMid meet");
    return image;
  }

  function setImageHref(image, resource) {
    image.setAttribute("href", resource.uri);
    image.setAttributeNS("http://www.w3.org/1999/xlink", "href", resource.uri);
    image.addEventListener("error", () => {
      reportError("resource load failed id=" + resource.id + " kind=" + resource.kind + " path=" + resource.path);
    });
  }

  function renderResourceFallback(item) {
    return renderTextItem({
      type: "text",
      nodeId: item.nodeId,
      frame: item.frame,
      lines: [{
        baselineY: item.frame.y + 14,
        spans: [{
          kind: "glyphs",
          x: 0,
          text: "resource",
          fontFamily: "Helvetica",
          fontWeight: 400,
          fontStyle: "normal",
          fontSize: 14,
          color: [0.35, 0.39, 0.45],
          linkUrl: null,
          strikethrough: false,
        }],
      }],
    });
  }

  function renderObject(svg, object) {
    const group = document.createElementNS(svgNamespace, "g");
    group.classList.add("object");
    if (selectedObjectId === object.id) {
      group.classList.add("selected");
    }
    if (object.interaction && object.interaction.movable) {
      group.classList.add("movable");
    } else {
      group.classList.add("locked");
    }
    if (isGroupObject(object)) {
      group.classList.add("groupObject");
    }
    group.dataset.objectId = String(object.id);

    const rect = document.createElementNS(svgNamespace, "rect");
    rect.classList.add("objectRect");
    rect.setAttribute("x", String(object.frame.x));
    rect.setAttribute("y", String(object.frame.y));
    rect.setAttribute("width", String(Math.max(1, object.frame.width)));
    rect.setAttribute("height", String(Math.max(1, object.frame.height)));
    group.appendChild(rect);

    const label = document.createElementNS(svgNamespace, "text");
    label.classList.add("objectLabel");
    label.textContent = object.label || String(object.id);
    label.setAttribute("x", String(object.frame.x + 4));
    label.setAttribute("y", String(Math.max(12, object.frame.y + 14)));
    group.appendChild(label);

    group.addEventListener("pointerdown", (event) => beginDrag(event, svg, object, group));
    group.addEventListener("dblclick", () => revealSource(object));

    return group;
  }

  function beginDrag(event, svg, object, group) {
    event.preventDefault();
    selectObject(svg, object);
    if (!object.interaction || !object.interaction.movable) {
      setStatus(object.interaction && object.interaction.message ? object.interaction.message : "");
      reportLog("select locked node=" + object.id);
      return;
    }
    group.setPointerCapture(event.pointerId);
    const point = svgPoint(svg, event);
    drag = {
      svg,
      group,
      object,
      pointerId: event.pointerId,
      startPoint: point,
      initialFrame: { ...object.frame },
      currentFrame: { ...object.frame },
      relative: event.shiftKey,
    };
    shiftDown = event.shiftKey;
    setEditMode(drag.relative);
    reportLog("drag start node=" + object.id + " mode=" + (drag.relative ? "relative" : "absolute") + " x=" + object.frame.x.toFixed(1) + " y=" + object.frame.y.toFixed(1));
    group.classList.add("dragging");
    group.classList.toggle("relativeDrag", drag.relative);
    group.addEventListener("pointermove", updateDrag);
    group.addEventListener("pointerup", endDrag);
    group.addEventListener("pointercancel", cancelDrag);
  }

  function updateDrag(event) {
    if (!drag || event.pointerId !== drag.pointerId) {
      return;
    }
    const point = svgPoint(drag.svg, event);
    const dx = point.x - drag.startPoint.x;
    const dy = point.y - drag.startPoint.y;
    drag.relative = event.shiftKey;
    shiftDown = event.shiftKey;
    setEditMode(drag.relative);
    drag.group.classList.toggle("relativeDrag", drag.relative);
    drag.currentFrame = {
      ...drag.initialFrame,
      x: drag.initialFrame.x + dx,
      y: drag.initialFrame.y + dy,
    };
    moveObjectGroup(drag.group, drag.currentFrame);
  }

  function endDrag(event) {
    if (!drag || event.pointerId !== drag.pointerId) {
      return;
    }
    const completed = drag;
    cleanupDrag();
    const dx = completed.currentFrame.x - completed.initialFrame.x;
    const dy = completed.currentFrame.y - completed.initialFrame.y;
    if (Math.abs(dx) < 0.25 && Math.abs(dy) < 0.25) {
      moveObjectGroup(completed.group, completed.initialFrame);
      return;
    }
    const object = completed.object;
    const mode = event.shiftKey || completed.relative ? "relative" : "absolute";
    const requestId = nextGestureRequestId++;
    pendingGestures.set(requestId, {
      objectId: object.id,
      pageId: object.pageId,
      group: completed.group,
      initialFrame: completed.initialFrame,
    });
    completed.group.dataset.pendingGestureId = String(requestId);
    reportLog("drag end node=" + object.id + " mode=" + mode + " snapshot=" + snapshot.snapshotId + " version=" + snapshot.documentVersion + " dx=" + dx.toFixed(1) + " dy=" + dy.toFixed(1) + " x=" + completed.currentFrame.x.toFixed(1) + " y=" + completed.currentFrame.y.toFixed(1));
    vscode.postMessage({
      type: "gesture",
      requestId,
      snapshotId: snapshot.snapshotId,
      selection: {
        primaryNodeId: object.id,
        targets: [{
          nodeId: object.id,
          pageId: object.pageId,
          initialFrame: completed.initialFrame,
        }],
      },
      gesture: {
        kind: "translate",
        mode,
        coordinateSpace: "page",
        fromBounds: completed.initialFrame,
        toBounds: completed.currentFrame,
        delta: { dx, dy },
      },
    });
  }

  function finishPendingGesture(message) {
    const requestId = Number(message.requestId);
    const pending = pendingGestures.get(requestId);
    if (!pending) {
      return;
    }
    pendingGestures.delete(requestId);
    const group = currentObjectGroup(pending);
    const ownsGroup = group && group.dataset.pendingGestureId === String(requestId);
    if (ownsGroup) {
      delete group.dataset.pendingGestureId;
    }
    if (message.status === "ok") {
      reportLog("layout edit accepted request=" + requestId + " node=" + pending.objectId);
      return;
    }
    if (ownsGroup) {
      moveObjectGroup(group, pending.initialFrame);
      reportLog("layout edit reverted request=" + requestId + " status=" + message.status + " node=" + pending.objectId);
    }
  }

  function currentObjectGroup(pending) {
    if (pending.group && pending.group.isConnected) {
      return pending.group;
    }
    const page = pagesElement.querySelector('.pageOverlay[data-page-id="' + pending.pageId + '"]');
    return page ? page.querySelector('.object[data-object-id="' + pending.objectId + '"]') : undefined;
  }

  function cancelDrag(event) {
    if (!drag || event.pointerId !== drag.pointerId) {
      return;
    }
    reportLog("drag cancel node=" + drag.object.id);
    moveObjectGroup(drag.group, drag.initialFrame);
    cleanupDrag();
  }

  function cleanupDrag() {
    if (!drag) {
      return;
    }
    drag.group.classList.remove("dragging");
    drag.group.classList.remove("relativeDrag");
    drag.group.releasePointerCapture(drag.pointerId);
    drag.group.removeEventListener("pointermove", updateDrag);
    drag.group.removeEventListener("pointerup", endDrag);
    drag.group.removeEventListener("pointercancel", cancelDrag);
    drag = undefined;
    setEditMode(shiftDown);
  }

  function moveObjectGroup(group, frame) {
    const rect = group.querySelector(".objectRect");
    const label = group.querySelector(".objectLabel");
    rect.setAttribute("x", String(frame.x));
    rect.setAttribute("y", String(frame.y));
    label.setAttribute("x", String(frame.x + 4));
    label.setAttribute("y", String(Math.max(12, frame.y + 14)));
  }

  function selectObject(svg, object) {
    if (selectedObjectId === object.id) {
      updateSelectionClasses(svg);
      renderRelations(svg, object.pageId);
      return;
    }
    selectedObjectId = object.id;
    updateSelectionClasses(svg);
    renderRelations(svg, object.pageId);
  }

  function updateSelectionClasses(svg) {
    for (const node of svg.querySelectorAll(".object")) {
      node.classList.toggle("selected", Number.parseInt(node.dataset.objectId || "0", 10) === selectedObjectId);
    }
  }

  function renderRelations(svg, pageId) {
    const group = svg.querySelector(".relations");
    if (!group) {
      return;
    }
    group.replaceChildren();
    if (selectedObjectId === undefined) {
      return;
    }
    const page = (snapshot.pages || []).find((candidate) => candidate.id === pageId);
    if (!page) {
      return;
    }
    for (const relation of relationsForPage(pageId)) {
      if (relation.targetNode !== selectedObjectId && relation.sourceNode !== selectedObjectId) {
        continue;
      }
      const element = renderRelation(page, relation);
      if (element) {
        group.appendChild(element);
      }
    }
  }

  function renderRelation(page, relation) {
    const target = objectById(relation.targetNode);
    if (!target) {
      return undefined;
    }
    const targetPoint = anchorPoint(target.frame, relation.targetAnchor, page.frame, undefined);
    const sourcePoint = relation.sourceKind === "page"
      ? anchorPoint(page.frame, relation.sourceAnchor, page.frame, targetPoint)
      : anchorPointForObject(relation.sourceNode, relation.sourceAnchor, page.frame);
    if (!sourcePoint || !targetPoint) {
      return undefined;
    }

    const group = document.createElementNS(svgNamespace, "g");
    group.classList.add("relation");
    group.classList.add(relation.kind === "fallback" ? "fallback" : "explicit");
    group.classList.add(relation.sourceKind === "page" ? "pageSource" : "nodeSource");
    group.classList.add(relation.axis === "vertical" ? "vertical" : "horizontal");

    const line = document.createElementNS(svgNamespace, "line");
    line.classList.add("relationLine");
    line.setAttribute("x1", String(sourcePoint.x));
    line.setAttribute("y1", String(sourcePoint.y));
    line.setAttribute("x2", String(targetPoint.x));
    line.setAttribute("y2", String(targetPoint.y));
    group.appendChild(line);

    group.appendChild(anchorMarker(sourcePoint, relation.sourceAnchor, "source"));
    group.appendChild(anchorMarker(targetPoint, relation.targetAnchor, "target"));

    const label = document.createElementNS(svgNamespace, "text");
    label.classList.add("relationLabel");
    label.textContent = relation.targetAnchor;
    label.setAttribute("x", String((sourcePoint.x + targetPoint.x) / 2 + 4));
    label.setAttribute("y", String((sourcePoint.y + targetPoint.y) / 2 - 4));
    group.appendChild(label);
    return group;
  }

  function anchorMarker(point, anchor, role) {
    const group = document.createElementNS(svgNamespace, "g");
    group.classList.add("anchorMarker");
    group.classList.add(role);
    const dot = document.createElementNS(svgNamespace, "circle");
    dot.setAttribute("cx", String(point.x));
    dot.setAttribute("cy", String(point.y));
    dot.setAttribute("r", "3.5");
    group.appendChild(dot);

    const text = document.createElementNS(svgNamespace, "text");
    text.textContent = anchor;
    text.setAttribute("x", String(point.x + 5));
    text.setAttribute("y", String(point.y - 5));
    group.appendChild(text);
    return group;
  }

  function anchorPointForObject(nodeId, anchor, pageFrame) {
    const object = objectById(nodeId);
    return object ? anchorPoint(object.frame, anchor, pageFrame, undefined) : undefined;
  }

  function anchorPoint(frame, anchor, pageFrame, reference) {
    if (anchor === "left") {
      return { x: frame.x, y: reference ? reference.y : frame.y + frame.height / 2 };
    }
    if (anchor === "right") {
      return { x: frame.x + frame.width, y: reference ? reference.y : frame.y + frame.height / 2 };
    }
    if (anchor === "center_x") {
      return { x: frame.x + frame.width / 2, y: reference ? reference.y : frame.y + frame.height / 2 };
    }
    if (anchor === "top") {
      return { x: reference ? reference.x : frame.x + frame.width / 2, y: frame.y };
    }
    if (anchor === "bottom") {
      return { x: reference ? reference.x : frame.x + frame.width / 2, y: frame.y + frame.height };
    }
    if (anchor === "center_y") {
      return { x: reference ? reference.x : frame.x + frame.width / 2, y: frame.y + frame.height / 2 };
    }
    return { x: pageFrame.width / 2, y: pageFrame.height / 2 };
  }

  function displayPageFor(page) {
    return displayPagesByPageId.get(page.id) || displayPagesByIndex.get(page.index);
  }

  function objectsForPage(pageId) {
    return objectsByPageId.get(pageId) || [];
  }

  function objectHitOrder(a, b) {
    const aGroup = isGroupObject(a);
    const bGroup = isGroupObject(b);
    if (aGroup !== bGroup) {
      return aGroup ? -1 : 1;
    }
    return 0;
  }

  function isGroupObject(object) {
    return object && object.role === "group";
  }

  function objectById(id) {
    return objectsById.get(id);
  }

  function relationsForPage(pageId) {
    return relationsByPageId.get(pageId) || [];
  }

  function resourceById(id) {
    return resourcesById.get(id);
  }

  function svgPoint(svg, event) {
    const point = svg.createSVGPoint();
    point.x = event.clientX;
    point.y = event.clientY;
    const matrix = svg.getScreenCTM();
    if (!matrix) {
      return { x: 0, y: 0 };
    }
    return point.matrixTransform(matrix.inverse());
  }

  function revealSource(object) {
    if (!object.source) {
      return;
    }
    reportLog("reveal source node=" + object.id);
    vscode.postMessage({
      type: "reveal-source",
      uri: object.source.uri,
      range: object.source.range,
    });
  }

  function captureView() {
    const top = pagesElement.scrollTop;
    const holders = pagesElement.querySelectorAll(".page");
    for (const holder of holders) {
      if (holder.offsetTop + holder.offsetHeight >= top + 8) {
        return {
          page: Number.parseInt(holder.dataset.page || "1", 10),
          offset: top - holder.offsetTop,
        };
      }
    }
    return { page: 1, offset: 0 };
  }

  function restoreView(previousView) {
    const holder = pageHolder(previousView.page || 1);
    if (!holder) {
      pagesElement.scrollTop = 0;
      return;
    }
    pagesElement.scrollTop = Math.max(0, holder.offsetTop + (previousView.offset || 0));
  }

  function pageHolder(page) {
    return pagesElement.querySelector('.page[data-page="' + page + '"]');
  }

  function zoomBy(factor) {
    if (!snapshot) {
      return;
    }
    useFitWidth = false;
    scale = clamp(lastRenderedScale * factor, minScale, maxScale);
    renderCurrent(captureView());
  }

  function fitScale(pageWidth) {
    const availableWidth = Math.max(160, pagesElement.clientWidth - fitWidthInset);
    return clamp(availableWidth / pageWidth, minScale, maxScale);
  }

  function updateZoomValue() {
    zoomValue.textContent = Math.round(lastRenderedScale * 100) + "%";
  }

  function setControls(enabled) {
    zoomOut.disabled = !enabled;
    fitWidth.disabled = !enabled;
    zoomIn.disabled = !enabled;
  }

  function setStatus(message) {
    statusElement.textContent = message;
  }

  function setShiftDown(value) {
    shiftDown = value;
    if (drag) {
      drag.relative = value;
      drag.group.classList.toggle("relativeDrag", value);
    }
    setEditMode(value);
  }

  function setEditMode(relative) {
    document.body.classList.toggle("relativeMode", relative);
    if (!editModeElement) {
      return;
    }
    editModeElement.textContent = relative ? "Relative" : "Absolute";
    editModeElement.title = relative ? "Relative layout edit" : "Absolute layout edit";
    editModeElement.setAttribute("aria-label", relative ? "Relative layout edit" : "Absolute layout edit");
  }

  function setEmpty(text) {
    const empty = document.createElement("div");
    empty.className = "empty";
    empty.textContent = text;
    pagesElement.replaceChildren(empty);
  }

  function color(value, fallback) {
    if (!Array.isArray(value) || value.length < 3) {
      return fallback;
    }
    const r = clamp(Math.round(value[0] * 255), 0, 255);
    const g = clamp(Math.round(value[1] * 255), 0, 255);
    const b = clamp(Math.round(value[2] * 255), 0, 255);
    return "rgb(" + r + " " + g + " " + b + ")";
  }

  function reportError(message) {
    vscode.postMessage({ type: "log", message: "error " + message });
  }

  function reportLog(message) {
    vscode.postMessage({ type: "log", message });
  }

  function clamp(value, min, max) {
    return Math.min(Math.max(value, min), max);
  }

  function errorMessage(error) {
    return error instanceof Error ? error.message : String(error);
  }
}());
