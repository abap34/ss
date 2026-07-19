export async function prepareDocumentResources(root) {
  const ownerDocument = root.nodeType === 9 ? root : root.ownerDocument;
  if (!ownerDocument) throw new Error("missing document for embedded resources");
  const resources = new Map();
  let disposed = false;
  let styleSheetUrl = null;
  for (const element of root.querySelectorAll("script[data-ss-resource]")) {
    const key = element.dataset.ssResource;
    const mediaType = element.dataset.mediaType;
    if (!key || !mediaType || resources.has(key)) {
      throw new Error("invalid embedded resource store");
    }
    resources.set(key, {
      encoded: element.textContent.trim(),
      mediaType,
      url: null,
    });
    element.remove();
  }

  const resolve = (reference) => {
    if (disposed) throw new Error("embedded resource store was disposed");
    const resource = resources.get(reference);
    if (!resource) {
      if (reference.startsWith("ss-resource:")) {
        throw new Error("missing embedded resource");
      }
      return reference;
    }
    if (!resource.url) {
      const binary = atob(resource.encoded);
      const bytes = new Uint8Array(binary.length);
      for (let index = 0; index < binary.length; index += 1) {
        bytes[index] = binary.charCodeAt(index);
      }
      resource.url = URL.createObjectURL(
        new Blob([bytes], { type: resource.mediaType }),
      );
      resource.encoded = "";
    }
    return resource.url;
  };

  const dispose = () => {
    if (disposed) return;
    disposed = true;
    for (const resource of resources.values()) {
      if (resource.url) URL.revokeObjectURL(resource.url);
      resource.url = null;
      resource.encoded = "";
    }
    if (styleSheetUrl) URL.revokeObjectURL(styleSheetUrl);
    styleSheetUrl = null;
  };

  const replaceResources = (value) => {
    let result = value;
    for (const key of resources.keys()) {
      if (result.includes(key)) result = result.replaceAll(key, resolve(key));
    }
    return result;
  };

  try {
    for (const element of root.querySelectorAll("[data-ss-src]")) {
      element.src = resolve(element.dataset.ssSrc);
      element.removeAttribute("data-ss-src");
    }
    for (const element of root.querySelectorAll("[style]")) {
      const current = element.getAttribute("style");
      const rewritten = replaceResources(current);
      if (rewritten !== current) element.setAttribute("style", rewritten);
    }

    const styleSource = root.querySelector("script[data-ss-stylesheet]");
    if (!styleSource) throw new Error("missing embedded style sheet");
    const styleSourceUrl = styleSource.textContent.trim();
    const template = await fetch(styleSourceUrl).then((response) => {
      if (!response.ok) throw new Error("failed to load embedded style sheet");
      return response.text();
    });
    const styleSheet = ownerDocument.createElement("link");
    styleSheet.rel = "stylesheet";
    const loaded = new Promise((resolveLoaded, reject) => {
      styleSheet.addEventListener("load", resolveLoaded, { once: true });
      styleSheet.addEventListener(
        "error",
        () => reject(new Error("failed to apply embedded style sheet")),
        { once: true },
      );
    });
    styleSheetUrl = URL.createObjectURL(
      new Blob([replaceResources(template)], { type: "text/css" }),
    );
    styleSheet.href = styleSheetUrl;
    styleSource.replaceWith(styleSheet);
    await loaded;
    await ownerDocument.fonts.ready;
    return Object.freeze({ resolve, dispose });
  } catch (error) {
    dispose();
    throw error;
  }
}
