import * as pdfjs from "./pdfjs/pdf.mjs";
import { renderPdfPages } from "./pdf.js";

await document.fonts.ready;
await renderPdfPages(document, pdfjs, "./pdfjs/pdf.worker.mjs");
document.documentElement.dataset.ssReady = "true";
