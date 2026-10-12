import { getDocumentRenderViewport } from '../documentViewport';

describe('continuous document viewport', () => {
  it('starts with one page rather than allocating the full notebook', () => {
    expect(getDocumentRenderViewport(null, 800, 1000, 100, 16)).toEqual({
      leftRatio: 0, topRatio: 0, widthRatio: 1, heightRatio: 0.01,
    });
  });
  it('accounts for centered pages, padding, and zoom around the viewport center', () => {
    const result = getDocumentRenderViewport({scale: 2, translateX: -100, translateY: -2000,
      containerWidth: 1000, containerHeight: 800}, 800, 1000, 100, 16);
    expect(result.leftRatio).toBeCloseTo(200 / 800);
    expect(result.topRatio).toBeCloseTo(1184 / 100000);
    expect(result.widthRatio).toBeCloseTo(500 / 800);
    expect(result.heightRatio).toBeCloseTo(400 / 100000);
  });
  it('keeps overscroll and last-page crops inside document bounds', () => {
    for (const translateY of [-1e6, 1e6]) {
      const result = getDocumentRenderViewport({scale: 1, translateX: 0, translateY,
        containerWidth: 1000, containerHeight: 800}, 800, 1000, 2, 16);
      expect(result.topRatio).toBeGreaterThanOrEqual(0);
      expect(result.topRatio + result.heightRatio).toBeLessThanOrEqual(1);
      expect(result.heightRatio).toBeGreaterThan(0);
    }
  });
});
