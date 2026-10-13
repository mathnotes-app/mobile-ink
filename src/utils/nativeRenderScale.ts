const NATIVE_RENDER_SCALE_BUCKETS = [1, 1.5, 2, 2.5, 3, 4, 5] as const;

export const MAX_NATIVE_DRAWABLE_PIXELS = 24_000_000;

export const getNativeRenderScaleBudget = (
  pageWidth: number,
  pageHeight: number,
  deviceScale: number,
) => {
  const basePixelArea = pageWidth * pageHeight * deviceScale * deviceScale;
  if (!Number.isFinite(basePixelArea) || basePixelArea <= 0) {
    return 1;
  }

  return Math.max(1, Math.min(5, Math.sqrt(MAX_NATIVE_DRAWABLE_PIXELS / basePixelArea)));
};

const finiteOr = (value: number, fallback: number) => (Number.isFinite(value) ? value : fallback);
const renderScaleLimit = (maxScale: number) => Math.max(1, finiteOr(maxScale, 1));
const clampRenderScale = (scale: number, maxScale: number) =>
  Math.max(1, Math.min(renderScaleLimit(maxScale), finiteOr(scale, 1)));

/** The highest bucket at or below `scale`. */
export const quantizeNativeRenderScale = (scale: number, maxScale: number) => {
  const target = clampRenderScale(scale, maxScale);
  let selected: number = NATIVE_RENDER_SCALE_BUCKETS[0];
  for (const bucket of NATIVE_RENDER_SCALE_BUCKETS) {
    if (bucket <= target + 0.001) selected = bucket;
  }
  return selected;
};

/** The bucket native iOS would choose for `scale` (nearest, ties toward lower). */
export const nearestNativeRenderScale = (scale: number, maxScale: number) => {
  const limit = renderScaleLimit(maxScale);
  const target = clampRenderScale(scale, maxScale);
  let selected: number = NATIVE_RENDER_SCALE_BUCKETS[0];
  for (const bucket of NATIVE_RENDER_SCALE_BUCKETS) {
    if (bucket <= limit + 0.001 && Math.abs(bucket - target) < Math.abs(selected - target)) selected = bucket;
  }
  return selected;
};
