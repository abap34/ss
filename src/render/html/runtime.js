await document.fonts.ready;

const pdf = await import("./pdf.js");
await pdf.ready;

document.documentElement.dataset.ssReady = "true";
