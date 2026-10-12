import { getVisibleContentRect } from "../utils/viewportTransform";
import type { ViewportTransformLike } from "../utils/viewportTransform";

const clamp = (value: number, min: number, max: number) => (
  Math.max(min, Math.min(max, value))
);

/** Native viewport ratios for a page in the centered continuous page stack. */
export function getPageRenderViewport(
  transform: ViewportTransformLike | null,
  pageIndex: number | null,
  pageWidth: number,
  pageHeight: number,
  contentPadding: number,
) {
  if (!transform || pageIndex === null || pageWidth <= 0 || pageHeight <= 0) {
    return {
      leftRatio: 0, topRatio: 0, widthRatio: 1, heightRatio: 1,
      intersectsViewport: true,
    };
  }

  const visible = getVisibleContentRect(transform);
  // Both offsets are in untransformed content coordinates. Subtract them
  // after undoing the viewport's center-origin scale and translation.
  const pageLeft = (transform.containerWidth - pageWidth) / 2;
  const pageTop = contentPadding + pageIndex * pageHeight;
  const left = clamp(visible.left - pageLeft, 0, pageWidth);
  const right = clamp(visible.right - pageLeft, 0, pageWidth);
  const top = clamp(visible.top - pageTop, 0, pageHeight);
  const bottom = clamp(visible.bottom - pageTop, 0, pageHeight);

  return {
    leftRatio: left / pageWidth,
    topRatio: top / pageHeight,
    widthRatio: clamp(Math.max(1, right - left) / pageWidth, 0.001, 1),
    heightRatio: clamp(Math.max(1, bottom - top) / pageHeight, 0.001, 1),
    intersectsViewport: right > left && bottom > top,
  };
}
