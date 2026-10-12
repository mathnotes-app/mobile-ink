import { getVisibleContentRect, type ViewportTransformLike } from './viewportTransform';

/** Ratios into a whole document, bounded to the visible part of the canvas. */
export function getDocumentRenderViewport(
  transform: ViewportTransformLike | null,
  pageWidth: number,
  pageHeight: number,
  pageCount: number,
  contentPadding: number,
) {
  const width = Math.max(1, pageWidth);
  const height = Math.max(1, pageHeight * Math.max(1, pageCount));
  const visible = transform ? getVisibleContentRect(transform)
    : { left: 0, top: contentPadding, width, height: pageHeight };
  const pageLeft = ((transform?.containerWidth ?? width) - width) / 2;
  const left = Math.max(0, Math.min(width - 1, visible.left - pageLeft));
  const top = Math.max(0, Math.min(height - 1, visible.top - contentPadding));
  const right = Math.min(width, visible.left + visible.width - pageLeft);
  const bottom = Math.min(height, visible.top + visible.height - contentPadding);
  return {
    leftRatio: left / width,
    topRatio: top / height,
    widthRatio: Math.max(1, right - left) / width,
    heightRatio: Math.max(1, bottom - top) / height,
  };
}
