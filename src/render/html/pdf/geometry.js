export function pageGeometry(page, container, view, options) {
  const selectedBox = pageBox(container);
  const rotation = pageRotation(container);
  const unitViewport = page.getViewport({ scale: 1, rotation });
  const unitSelection = normalizedRectangle(
    unitViewport.convertToViewportRectangle(selectedBox),
  );
  if (unitSelection.width <= 0 || unitSelection.height <= 0) {
    throw new Error("invalid PDF page box");
  }

  const style = view.getComputedStyle(container);
  const logicalWidth = positiveNumber(style.width, "PDF canvas width");
  const logicalHeight = positiveNumber(style.height, "PDF canvas height");
  const viewport = page.getViewport({
    scale: logicalWidth / unitSelection.width,
    rotation,
  });
  const selection = normalizedRectangle(
    viewport.convertToViewportRectangle(selectedBox),
  );
  const pixelSize = visiblePixelSize(container, view, options.maximumCanvasPixels);
  const rasterScaleX = pixelSize.width / selection.width;
  const rasterScaleY = pixelSize.height / selection.height;
  return {
    viewport,
    selection,
    logicalWidth,
    logicalHeight,
    pixelWidth: pixelSize.width,
    pixelHeight: pixelSize.height,
    rasterTransform: [
      rasterScaleX,
      0,
      0,
      rasterScaleY,
      -selection.left * rasterScaleX,
      -selection.top * rasterScaleY,
    ],
  };
}

export function visiblePixelSize(container, view, maximumPixels) {
  const bounds = container.getBoundingClientRect();
  const deviceScale = positiveNumber(
    view.devicePixelRatio || 1,
    "device pixel ratio",
  );
  return limitedPixelSize(
    bounds.width * deviceScale,
    bounds.height * deviceScale,
    maximumPixels,
  );
}

function limitedPixelSize(width, height, maximumPixels) {
  const limit = positiveNumber(maximumPixels, "maximum PDF canvas pixels");
  let pixelWidth = Math.max(1, Math.round(width));
  let pixelHeight = Math.max(1, Math.round(height));
  const pixels = pixelWidth * pixelHeight;
  if (pixels > limit) {
    const scale = Math.sqrt(limit / pixels);
    pixelWidth = Math.max(1, Math.floor(pixelWidth * scale));
    pixelHeight = Math.max(1, Math.floor(pixelHeight * scale));
  }
  return { width: pixelWidth, height: pixelHeight };
}

function pageBox(container) {
  const values = container.dataset.viewBox?.split(",").map(Number);
  if (!values || values.length !== 4 ||
      values.some((value) => !Number.isFinite(value))) {
    throw new Error("invalid PDF page box metadata");
  }
  return values;
}

function pageRotation(container) {
  const rotation = Number(container.dataset.rotation);
  if (![0, 90, 180, 270].includes(rotation)) {
    throw new Error("invalid PDF page rotation metadata");
  }
  return rotation;
}

function normalizedRectangle(values) {
  if (!Array.isArray(values) || values.length !== 4 ||
      values.some((value) => !Number.isFinite(value))) {
    throw new Error("invalid PDF viewport rectangle");
  }
  const left = Math.min(values[0], values[2]);
  const top = Math.min(values[1], values[3]);
  const right = Math.max(values[0], values[2]);
  const bottom = Math.max(values[1], values[3]);
  return {
    left,
    top,
    right,
    bottom,
    width: right - left,
    height: bottom - top,
  };
}

function positiveNumber(value, label) {
  const number = Number.parseFloat(value);
  if (!Number.isFinite(number) || number <= 0) {
    throw new Error("invalid " + label);
  }
  return number;
}
