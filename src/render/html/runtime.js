import * as pdfjs from "./pdfjs/pdf.mjs";
import { renderPdfPages } from "./pdf.js";

await document.fonts.ready;
try {
  await renderPdfPages(document, pdfjs, "./pdfjs/pdf.worker.mjs");
} catch (error) {
  document.documentElement.dataset.ssError = error instanceof Error ? error.message : String(error);
  throw error;
} finally {
  document.documentElement.dataset.ssReady = "true";
}
