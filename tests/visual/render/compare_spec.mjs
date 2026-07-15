import assert from "node:assert/strict";
import { PNG } from "pngjs";
import { compareImages, decodePng, encodePng } from "./compare.mjs";

const white = image(4, 3, [255, 255, 255, 255]);
const same = decodePng(encodePng(white));
assert.equal(compareImages(white, same).pass, true);

const wrongSize = image(3, 4, [255, 255, 255, 255]);
assert.deepEqual(compareImages(white, wrongSize).reason, "dimensions");

const changed = image(4, 3, [255, 255, 255, 255]);
changed.data[0] = 0;
const strict = compareImages(white, changed, {
  meanAbsoluteError: 0,
  largeDifference: 8 / 255,
  largeDifferenceRatio: 0,
});
assert.equal(strict.pass, false);
assert.equal(strict.largeDifferencePixels, 1);
assert.equal(strict.diff.data[0], 255);

const tolerated = compareImages(white, changed, {
  meanAbsoluteError: 1 / (4 * 3 * 4),
  largeDifference: 8 / 255,
  largeDifferenceRatio: 1 / 12,
});
assert.equal(tolerated.pass, true);

const shiftedLeft = image(4, 3, [255, 255, 255, 255]);
const shiftedRight = image(4, 3, [255, 255, 255, 255]);
shiftedLeft.data[4 * (1 * 4 + 1)] = 0;
shiftedRight.data[4 * (1 * 4 + 2)] = 0;
const spatiallyTolerated = compareImages(shiftedLeft, shiftedRight, {
  meanAbsoluteError: 0,
  largeDifference: 8 / 255,
  largeDifferenceRatio: 0,
  spatialTolerance: 1,
});
assert.equal(spatiallyTolerated.pass, true);

function image(width, height, color) {
  const result = new PNG({ width, height });
  for (let offset = 0; offset < result.data.length; offset += 4) {
    result.data.set(color, offset);
  }
  return result;
}
