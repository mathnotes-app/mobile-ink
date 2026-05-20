import { selectionBoundsToTouchRect } from "../infinite-ink-canvas/selectionTouchRects";

describe("selectionBoundsToTouchRect", () => {
  it("converts page-local selection bounds into viewport content coordinates", () => {
    expect(selectionBoundsToTouchRect({
      bounds: { x: 100, y: 120, width: 240, height: 180 },
      pageIndex: 2,
      pageWidth: 820,
      pageHeight: 1061,
      contentPadding: 16,
      containerWidth: 1024,
      padding: 24,
    })).toEqual({
      left: 178,
      top: 2234,
      right: 466,
      bottom: 2462,
    });
  });

  it("returns null for empty or unknown selection bounds", () => {
    expect(selectionBoundsToTouchRect({
      bounds: null,
      pageIndex: 0,
      pageWidth: 820,
      pageHeight: 1061,
      contentPadding: 16,
      containerWidth: 1024,
    })).toBeNull();

    expect(selectionBoundsToTouchRect({
      bounds: { x: 0, y: 0, width: 0, height: 100 },
      pageIndex: 0,
      pageWidth: 820,
      pageHeight: 1061,
      contentPadding: 16,
      containerWidth: 1024,
    })).toBeNull();
  });
});
