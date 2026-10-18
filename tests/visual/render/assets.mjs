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

export { pdfAsset } from "../../support/assets/pdf.mjs";
