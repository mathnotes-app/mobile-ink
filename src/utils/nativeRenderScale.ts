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

export const quantizeNativeRenderScale = (scale: number, maxScale: number) => {
  const targetScale = Math.max(
    1,
    Math.min(
      Number.isFinite(maxScale) ? maxScale : 1,
      Number.isFinite(scale) ? scale : 1,
    ),
  );
  let selected: number = NATIVE_RENDER_SCALE_BUCKETS[0];
  for (const bucket of NATIVE_RENDER_SCALE_BUCKETS) {
    if (bucket <= targetScale + 0.001) {
      selected = bucket;
    }
  }

  return selected;
};
