import type { TouchExclusionRect } from "../ZoomableInkViewport";
import type { NativeSelectionBounds } from "../types";

export const SELECTION_TOUCH_BLOCK_PADDING = 36;

export type SelectionTouchRectInput = {
  bounds: NativeSelectionBounds | null;
  pageIndex: number;
  pageWidth: number;
  pageHeight: number;
  contentPadding: number;
  containerWidth: number;
  padding?: number;
};

export function selectionBoundsToTouchRect({
  bounds,
  pageIndex,
  pageWidth,
  pageHeight,
  contentPadding,
  containerWidth,
  padding = SELECTION_TOUCH_BLOCK_PADDING,
}: SelectionTouchRectInput): TouchExclusionRect | null {
  if (
    !bounds ||
    pageIndex < 0 ||
    bounds.width <= 0 ||
    bounds.height <= 0 ||
    !Number.isFinite(bounds.x) ||
    !Number.isFinite(bounds.y) ||
    !Number.isFinite(bounds.width) ||
    !Number.isFinite(bounds.height)
  ) {
    return null;
  }

  const pageOffsetX = (containerWidth - pageWidth) / 2;
  const left = pageOffsetX + bounds.x - padding;
  const top = contentPadding + pageIndex * pageHeight + bounds.y - padding;

  return {
    left,
    top,
    right: left + bounds.width + padding * 2,
    bottom: top + bounds.height + padding * 2,
  };
}
