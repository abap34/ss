import { PNG } from "pngjs";

export const defaultThresholds = Object.freeze({
  meanAbsoluteError: 0.001,
  largeDifference: 8 / 255,
  largeDifferenceRatio: 0.005,
});

export function decodePng(bytes) {
  return PNG.sync.read(bytes, { skipRescale: true });
}

export function compareImages(expected, actual, thresholds = defaultThresholds) {
  if (expected.width !== actual.width || expected.height !== actual.height) {
    return {
      pass: false,
      reason: "dimensions",
      expected: { width: expected.width, height: expected.height },
      actual: { width: actual.width, height: actual.height },
    };
  }

  const pixels = expected.width * expected.height;
  let absoluteError = 0;
  let largeDifferencePixels = 0;
  const diff = new PNG({ width: expected.width, height: expected.height });
  for (let pixel = 0; pixel < pixels; pixel += 1) {
    const offset = pixel * 4;
    let largestChannelDifference = 0;
    for (let channel = 0; channel < 4; channel += 1) {
      const difference = Math.abs(expected.data[offset + channel] - actual.data[offset + channel]);
      absoluteError += difference;
      largestChannelDifference = Math.max(largestChannelDifference, difference);
    }
    if (largestChannelDifference / 255 > thresholds.largeDifference) largeDifferencePixels += 1;
    diff.data[offset] = largestChannelDifference;
    diff.data[offset + 1] = 0;
    diff.data[offset + 2] = 0;
    diff.data[offset + 3] = 255;
  }

  const meanAbsoluteError = absoluteError / (pixels * 4 * 255);
  const largeDifferenceRatio = largeDifferencePixels / pixels;
  return {
    pass: meanAbsoluteError <= thresholds.meanAbsoluteError &&
      largeDifferenceRatio <= thresholds.largeDifferenceRatio,
    reason: "pixels",
    meanAbsoluteError,
    largeDifferencePixels,
    largeDifferenceRatio,
    diff,
  };
}

export function encodePng(image) {
  return PNG.sync.write(image, { colorType: 6 });
}
