import { PixelRatio } from 'react-native';
import { getDocumentRenderViewport } from './documentViewport';
import { nearestNativeRenderScale, quantizeNativeRenderScale } from './nativeRenderScale';
import type { ViewportTransformLike } from './viewportTransform';

/** Crop and resolution for a continuous-document native ink surface. */
export type DocumentRenderTarget = {
  renderScale: number;
  leftRatio: number;
  topRatio: number;
  widthRatio: number;
  heightRatio: number;
};

export type DocumentRenderLayout = {
  pageWidth: number;
  pageHeight: number;
  pageCount: number;
  contentPadding: number;
  /** Device pixels per point; defaults to PixelRatio.get(). */
  pixelRatio?: number;
  /** Highest native render scale; defaults to MAX_NATIVE_RENDER_SCALE. */
  maxRenderScale?: number;
};

/** Native engines clamp render scale to this (kMaximumRenderScale in C++). */
export const MAX_NATIVE_RENDER_SCALE = 5;

// Native iOS caps a continuous drawable at 4096 px per side; stay below it so
// the native clamp never truncates the overscan asymmetrically.
const MAX_TARGET_SIDE_PIXELS = 4000;
// Fraction of the visible size rendered beyond each visible edge, so a pan
// re-renders only after it moves this far instead of on every frame.
const OVERSCAN_FRACTION = 0.5;

type Rect = { left: number; top: number; right: number; bottom: number };

const toRect = (target: Pick<DocumentRenderTarget, 'leftRatio' | 'topRatio' | 'widthRatio' | 'heightRatio'>,
  width: number, height: number): Rect => ({
  left: target.leftRatio * width,
  top: target.topRatio * height,
  right: (target.leftRatio + target.widthRatio) * width,
  bottom: (target.topRatio + target.heightRatio) * height,
});

const contains = (outer: Rect, inner: Rect) => (
  inner.left >= outer.left - 0.5 && inner.top >= outer.top - 0.5 &&
  inner.right <= outer.right + 0.5 && inner.bottom <= outer.bottom + 0.5
);

const fitsPixelCap = (rect: Rect, scale: number, pixelRatio: number) => {
  const pointsLimit = MAX_TARGET_SIDE_PIXELS / (pixelRatio * scale);
  return rect.right - rect.left <= pointsLimit && rect.bottom - rect.top <= pointsLimit;
};

/** Grow a visible span by the overscan, capped and clamped to [0, extent]. */
const expandSpan = (start: number, end: number, extent: number, limit: number): [number, number] => {
  const size = end - start;
  const desired = Math.max(size, Math.min(limit, size * (1 + 2 * OVERSCAN_FRACTION)));
  const length = Math.min(extent, desired);
  const center = (start + end) / 2;
  const from = Math.max(0, Math.min(extent - length, center - length / 2));
  return [from, from + length];
};

/**
 * Returns `previous` unchanged while it still covers the visible document at
 * the wanted resolution, so a pan or pinch does not re-render native ink every
 * frame. While `isMoving`, the previous resolution is held (the view transform
 * scales it) until the visible area no longer fits it; the settled call then
 * resolves the crisp scale.
 */
export function resolveDocumentRenderTarget(
  previous: DocumentRenderTarget | null,
  transform: ViewportTransformLike | null,
  layout: DocumentRenderLayout,
  isMoving: boolean,
): DocumentRenderTarget {
  // Layout can be degenerate before the first native layout; never let NaN or
  // Infinity reach native frame geometry.
  const finite = (value: number, fallback: number) => (Number.isFinite(value) ? value : fallback);
  const pageWidth = Math.max(1, finite(layout.pageWidth, 1));
  const pageHeight = Math.max(1, finite(layout.pageHeight, 1));
  const pageCount = Math.max(1, finite(layout.pageCount, 1));
  const contentPadding = Math.max(0, finite(layout.contentPadding, 0));
  const width = pageWidth;
  const height = pageHeight * pageCount;
  const requestedRatio = layout.pixelRatio ?? PixelRatio.get();
  const pixelRatio = Math.max(1, Number.isFinite(requestedRatio) ? requestedRatio : 1);
  const maxRenderScale = layout.maxRenderScale ?? MAX_NATIVE_RENDER_SCALE;
  const visible = toRect(getDocumentRenderViewport(transform, pageWidth, pageHeight,
    pageCount, contentPadding), width, height);
  // Prefer the nearest bucket for crisp settled ink; the lower bucket always
  // fits because its visible pixels never exceed the screen's.
  const zoom = transform?.scale ?? 1;
  // Overview renders at screen density instead of allocating full-resolution
  // pixels for several pages and truncating them at the native drawable cap.
  const overviewScale = [0.25, 0.5, 0.75, 1].reduce((best, value) =>
    value <= zoom + 0.001 ? value : best, 0.25);
  const nearestScale = zoom < 1 ? overviewScale : nearestNativeRenderScale(zoom, maxRenderScale);
  const settledScale = fitsPixelCap(visible, nearestScale, pixelRatio)
    ? nearestScale : quantizeNativeRenderScale(zoom, maxRenderScale);
  const scale = isMoving && previous && fitsPixelCap(visible, previous.renderScale, pixelRatio)
    ? previous.renderScale : settledScale;

  if (previous && previous.renderScale === scale) {
    // Ratios are relative to the document, so a page added since `previous`
    // can grow its rect past the native cap; re-resolve in that case.
    const rendered = toRect(previous, width, height);
    if (contains(rendered, visible) && fitsPixelCap(rendered, scale, pixelRatio)) return previous;
  }

  const limit = MAX_TARGET_SIDE_PIXELS / (pixelRatio * scale);
  const [left, right] = expandSpan(visible.left, visible.right, width, limit);
  const [top, bottom] = expandSpan(visible.top, visible.bottom, height, limit);
  return {
    renderScale: scale,
    leftRatio: left / width,
    topRatio: top / height,
    widthRatio: Math.max(1, right - left) / width,
    heightRatio: Math.max(1, bottom - top) / height,
  };
}
