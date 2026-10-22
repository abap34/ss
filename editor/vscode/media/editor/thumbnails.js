export function thumbnailPage(page) {
  const thumbnail = page.cloneNode(false);
  for (const item of page.children) {
    if (!item.classList.contains("ss-item")) continue;
    if (item.classList.contains("ss-text")) {
      thumbnail.append(textOutline(item));
    } else if (item.classList.contains("ss-pdf")) {
      thumbnail.append(item.cloneNode(false));
    } else {
      thumbnail.append(item.cloneNode(true));
    }
  }
  return thumbnail;
}

function textOutline(item) {
  const outline = item.cloneNode(false);
  outline.classList.remove("ss-text");
  for (const run of item.querySelectorAll(".ss-text-run")) {
    const line = item.ownerDocument.createElement("span");
    line.className = "thumbnail-text-line";
    line.style.cssText = run.style.cssText;
    line.style.fontFamily = "sans-serif";
    line.style.width = run.style.width || "100%";
    line.style.height = "0.45em";
    line.style.marginTop = "0.35em";
    outline.append(line);
  }
  return outline;
}
