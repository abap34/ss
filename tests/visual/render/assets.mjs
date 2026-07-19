import { PNG } from "pngjs";
import { encodePng } from "./compare.mjs";

export function rasterAsset() {
  const image = new PNG({ width: 320, height: 180 });
  for (let y = 0; y < image.height; y += 1) {
    for (let x = 0; x < image.width; x += 1) {
      const offset = (y * image.width + x) * 4;
      image.data[offset] = 220 + Math.floor(20 * x / image.width);
      image.data[offset + 1] = 235 + Math.floor(15 * y / image.height);
      image.data[offset + 2] = 245;
      image.data[offset + 3] = 255;
      if ((x - 160) ** 2 + (y - 90) ** 2 < 42 ** 2) {
        image.data[offset] = 240;
        image.data[offset + 1] = 138;
        image.data[offset + 2] = 93;
      }
    }
  }
  return encodePng(image);
}

export function pdfAsset() {
  const firstContent = "q\n0.18 0.44 0.56 rg\n0 0 240 120 re\nf\nQ\n";
  const secondContent = "q\n0.93 0.96 0.98 rg\n0 0 240 120 re\nf\n0.94 0.32 0.22 rg\n30 24 160 24 re\nf\nQ\nBT\n/F1 18 Tf\n24 72 Td\n(SelectablePdfToken) Tj\nET\nBT\n/F1 10 Tf\n24 36 Td\n(DragSelectablePdfToken) Tj\nET\nBT\n/F1 6 Tf\n2 4 Td\n(MediaMarginToken) Tj\nET\n";
  return buildPdf([
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 240 120] /Contents 5 0 R >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 240 120] /CropBox [20 10 220 110] /Rotate 90 /UserUnit 1.25 /Resources << /Font << /F1 7 0 R >> >> /Contents 6 0 R /Annots [8 0 R 9 0 R] >>",
    stream(firstContent),
    stream(secondContent),
    "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    "<< /Type /Annot /Subtype /Link /Rect [22 66 212 94] /Border [0 0 0] /A << /S /URI /URI (https://example.com/pdf) >> >>",
    "<< /Type /Annot /Subtype /Link /Rect [30 30 60 60] /Border [0 0 0] /Dest [3 0 R /Fit] >>",
  ]);
}

function stream(content) {
  return `<< /Length ${Buffer.byteLength(content)} >>\nstream\n${content}endstream`;
}

function buildPdf(objects) {
  let source = "%PDF-1.7\n";
  const offsets = [0];
  for (const [index, body] of objects.entries()) {
    offsets.push(Buffer.byteLength(source));
    source += `${index + 1} 0 obj\n${body}\nendobj\n`;
  }
  const xrefOffset = Buffer.byteLength(source);
  source += `xref\n0 ${objects.length + 1}\n0000000000 65535 f \n`;
  for (const offset of offsets.slice(1)) source += `${String(offset).padStart(10, "0")} 00000 n \n`;
  source += `trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n${xrefOffset}\n%%EOF\n`;
  return Buffer.from(source, "binary");
}
