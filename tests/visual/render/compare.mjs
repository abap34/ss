import { PNG } from "pngjs";

export const defaultThresholds = Object.freeze({
  meanAbsoluteError: 0.001,
  largeDifference: 8 / 255,
  largeDifferenceRatio: 0.005,
  spatialTolerance: 0,
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

  const spatialTolerance = thresholds.spatialTolerance ?? 0;
  if (spatialTolerance > 0) {
    return compareWithSpatialTolerance(expected, actual, thresholds, spatialTolerance);
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

function compareWithSpatialTolerance(expected, actual, thresholds, radius) {
  const forward = directionalDifference(expected, actual, thresholds, radius);
  const reverse = directionalDifference(actual, expected, thresholds, radius);
  const samples = forward.samples + reverse.samples;
  const meanAbsoluteError = (forward.absoluteError + reverse.absoluteError) /
    (samples * 4 * 255);
  const largeDifferencePixels = (forward.largeDifferencePixels + reverse.largeDifferencePixels) / 2;
  const largeDifferenceRatio = (forward.largeDifferencePixels + reverse.largeDifferencePixels) / samples;
  return {
    pass: meanAbsoluteError <= thresholds.meanAbsoluteError &&
      largeDifferenceRatio <= thresholds.largeDifferenceRatio,
    reason: "pixels",
    meanAbsoluteError,
    largeDifferencePixels,
    largeDifferenceRatio,
  };
}

function directionalDifference(source, candidate, thresholds, radius) {
  let absoluteError = 0;
  let largeDifferencePixels = 0;
  for (let y = 0; y < source.height; y += 1) {
    for (let x = 0; x < source.width; x += 1) {
      const sourceOffset = (y * source.width + x) * 4;
      let bestLargestDifference = Number.POSITIVE_INFINITY;
      let bestAbsoluteDifference = Number.POSITIVE_INFINITY;
      const minY = Math.max(0, y - radius);
      const maxY = Math.min(candidate.height - 1, y + radius);
      const minX = Math.max(0, x - radius);
      const maxX = Math.min(candidate.width - 1, x + radius);
      for (let candidateY = minY; candidateY <= maxY; candidateY += 1) {
        for (let candidateX = minX; candidateX <= maxX; candidateX += 1) {
          const candidateOffset = (candidateY * candidate.width + candidateX) * 4;
          let largestDifference = 0;
          let candidateAbsoluteDifference = 0;
          for (let channel = 0; channel < 4; channel += 1) {
            const difference = Math.abs(
              source.data[sourceOffset + channel] - candidate.data[candidateOffset + channel],
            );
            candidateAbsoluteDifference += difference;
            largestDifference = Math.max(largestDifference, difference);
          }
          if (largestDifference < bestLargestDifference ||
              (largestDifference === bestLargestDifference && candidateAbsoluteDifference < bestAbsoluteDifference)) {
            bestLargestDifference = largestDifference;
            bestAbsoluteDifference = candidateAbsoluteDifference;
          }
        }
      }
      absoluteError += bestAbsoluteDifference;
      if (bestLargestDifference / 255 > thresholds.largeDifference) largeDifferencePixels += 1;
    }
  }
  return {
    absoluteError,
    largeDifferencePixels,
    samples: source.width * source.height,
  };
}

export function encodePng(image) {
  return PNG.sync.write(image, { colorType: 6 });
}
