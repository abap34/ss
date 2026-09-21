export function start(root, presentation = null) {
  const pages = [...root.querySelectorAll(".ss-document > .ss-page")];
  const documentElement = root.documentElement ?? root.ownerDocument?.documentElement;
  if (pages.length === 0) {
    return {
      refresh() {},
      async prepareForPrint(renderAll) {
        await renderAll?.();
      },
      finishPrint() {},
      setPrintHandler() {},
    };
  }

  const container = root.querySelector(".ss-document");
  const presentationState = presentation?.createPresentationState();
  const presentationRoot = root.createElement("div");
  root.body.append(presentationRoot);
  const restorePages = () => container.append(...pages);
  const renderPresentation = () => {
    restorePages();
    presentationRoot.replaceChildren();
    if (presentationState.active) presentationRoot.append(presenter.render());
    else fit();
  };
  const presenter = presentation ? new presentation.PresentationController(presentationState, {
    getPages: () => pages.map((page, index) => ({
      id: index, width: parseFloat(page.style.width), height: parseFloat(page.style.height),
    })),
    renderPage: (index) => {
      const content = root.createElement("div");
      content.append(pages[index]);
      return content;
    },
    render: renderPresentation,
    onPageChange: (index) => {
      activate(index);
      history.replaceState(null, "", `#${index + 1}`);
    },
    onExit: () => {
      if (document.fullscreenElement) void document.exitFullscreen().catch(() => {});
    },
    toggleFullscreen: () => {
      const result = document.fullscreenElement
        ? document.exitFullscreen() : document.documentElement.requestFullscreen?.();
      void result?.catch(() => {});
    },
  }) : null;
  let startPresentation = documentElement?.hasAttribute("data-ss-present") ||
    new URLSearchParams(location.search).get("present") === "1";
  let activeIndex = 0;
  let printHandler = null;
  let printPreparation = null;
  let printPrepared = false;

  const fit = () => {
    const page = pages[activeIndex];
    const width = page.offsetWidth;
    const height = page.offsetHeight;
    if (width <= 0 || height <= 0) return;
    const scale = Math.min(window.innerWidth / width, window.innerHeight / height);
    page.style.setProperty("--ss-page-scale", String(Math.max(scale, 0)));
  };

  const activate = (index) => {
    activeIndex = Math.min(Math.max(index, 0), pages.length - 1);
    for (const [pageIndex, page] of pages.entries()) {
      const active = pageIndex === activeIndex;
      page.dataset.ssActive = String(active);
      page.setAttribute("aria-hidden", String(!active));
      if (active) page.setAttribute("aria-current", "page");
      else page.removeAttribute("aria-current");
    }
    fit();
  };

  const pageIndexFromHash = () => {
    const value = decodeHash(location.hash);
    if (/^[1-9][0-9]*$/.test(value)) {
      const pageNumber = Number(value);
      if (pageNumber <= pages.length) return pageNumber - 1;
    }
    if (value.length !== 0) {
      const destination = root.getElementById(value);
      const page = destination?.closest(".ss-page");
      const pageIndex = pages.indexOf(page);
      if (pageIndex >= 0) return pageIndex;
    }
    return 0;
  };

  const updateFromHash = () => {
    activate(pageIndexFromHash());
    if (presentationState?.active) presenter.goToIndex(activeIndex);
  };

  const move = (offset) => {
    const next = Math.min(Math.max(activeIndex + offset, 0), pages.length - 1);
    if (next === activeIndex) return;
    location.hash = String(next + 1);
  };

  const onKeyDown = (event) => {
    if (event.defaultPrevented || event.altKey || event.shiftKey) return;
    if (acceptsTextInput(event.target)) return;
    if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === "p") {
      if (!printHandler) return;
      event.preventDefault();
      printHandler();
      return;
    }
    if (event.ctrlKey || event.metaKey || presentationState?.active) return;
    if (event.key.toLowerCase() === "p" && presenter) {
      event.preventDefault();
      presenter.start(activeIndex);
      return;
    }
    if (event.key === "ArrowRight" || event.key === "ArrowDown") {
      event.preventDefault();
      move(1);
    } else if (event.key === "ArrowLeft" || event.key === "ArrowUp") {
      event.preventDefault();
      move(-1);
    }
  };

  window.addEventListener("hashchange", updateFromHash);
  window.addEventListener("resize", fit);
  window.visualViewport?.addEventListener("resize", fit);
  window.addEventListener("keydown", onKeyDown);
  window.addEventListener("beforeprint", restorePages);
  window.addEventListener("afterprint", () => {
    if (presentationState?.active) renderPresentation();
  });
  window.addEventListener("beforeunload", () => presenter?.dispose(), { once: true });
  root.fonts?.ready.then(fit);
  updateFromHash();

  return {
    refresh() {
      fit();
      if (startPresentation && presenter) {
        startPresentation = false;
        presenter.start(activeIndex);
      }
    },
    async prepareForPrint(renderAll) {
      if (printPrepared) return;
      if (!printPreparation) {
        restorePages();
        documentElement?.setAttribute("data-ss-print-layout", "true");
        printPreparation = (async () => {
          await nextFrame();
          await nextFrame();
          await renderAll?.();
          printPrepared = true;
        })();
      }
      try {
        await printPreparation;
      } catch (error) {
        documentElement?.removeAttribute("data-ss-print-layout");
        if (presentationState?.active) renderPresentation();
        fit();
        throw error;
      } finally {
        printPreparation = null;
      }
    },
    finishPrint() {
      printPrepared = false;
      documentElement?.removeAttribute("data-ss-print-layout");
      if (presentationState?.active) renderPresentation();
      fit();
    },
    setPrintHandler(handler) {
      printHandler = typeof handler === "function" ? handler : null;
    },
  };
}

function decodeHash(hash) {
  try {
    return decodeURIComponent(hash.replace(/^#/, ""));
  } catch {
    return "";
  }
}

function acceptsTextInput(target) {
  if (!(target instanceof Element)) return false;
  return target.matches("input, textarea, select, [contenteditable]:not([contenteditable='false'])");
}

function nextFrame() {
  return new Promise((resolve) => requestAnimationFrame(() => resolve()));
}
