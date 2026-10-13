import { resolveDocumentRenderTarget, type DocumentRenderTarget } from '../documentRenderTarget';

const layout = { pageWidth: 800, pageHeight: 1000, pageCount: 100, contentPadding: 16, pixelRatio: 2, maxRenderScale: 5 };
const at = (translateY: number, scale = 1, translateX = 0) => ({
  scale, translateX, translateY, containerWidth: 800, containerHeight: 600,
});
const rectOf = (t: DocumentRenderTarget, documentHeight = 100000) => ({
  top: t.topRatio * documentHeight, bottom: (t.topRatio + t.heightRatio) * documentHeight,
  left: t.leftRatio * 800, right: (t.leftRatio + t.widthRatio) * 800,
});

describe('continuous document render target', () => {
  it('renders beyond the visible rows so small pans reuse the same target', () => {
    const first = resolveDocumentRenderTarget(null, at(-5000), layout, true);
    const rect = rectOf(first);
    // Visible document rows are 4984..5584; overscan covers 300pt on each side.
    expect(rect.top).toBeCloseTo(4684);
    expect(rect.bottom).toBeCloseTo(5884);
    expect(resolveDocumentRenderTarget(first, at(-5200), layout, true)).toBe(first);
    expect(resolveDocumentRenderTarget(first, at(-4800), layout, true)).toBe(first);
    expect(resolveDocumentRenderTarget(first, at(-5200), layout, false)).toBe(first);
  });

  it('re-renders once the visible area leaves the rendered target', () => {
    const first = resolveDocumentRenderTarget(null, at(-5000), layout, true);
    const next = resolveDocumentRenderTarget(first, at(-5400), layout, true);
    expect(next).not.toBe(first);
    const rect = rectOf(next);
    expect(rect.top).toBeLessThanOrEqual(5384);
    expect(rect.bottom).toBeGreaterThanOrEqual(5984);
  });

  it('holds resolution during a pinch and sharpens when motion settles', () => {
    const settled = resolveDocumentRenderTarget(null, at(-5000), layout, false);
    expect(settled.renderScale).toBe(1);
    const pinching = resolveDocumentRenderTarget(settled, at(-10000, 2), layout, true);
    expect(pinching.renderScale).toBe(1);
    const released = resolveDocumentRenderTarget(pinching, at(-10000, 2), layout, false);
    expect(released.renderScale).toBe(2);
  });

  it('settles at the nearest resolution bucket when it fits the native cap', () => {
    expect(resolveDocumentRenderTarget(null, at(-10000, 1.4), layout, false).renderScale).toBe(1.5);
    expect(resolveDocumentRenderTarget(null, at(-10000, 3.6), layout, false).renderScale).toBe(4);
    expect(resolveDocumentRenderTarget(null, at(-10000, 3.6), { ...layout, maxRenderScale: 3 }, false).renderScale).toBe(3);
    // A full-height 2600pt view at 1.4x would need 2600 / 1.4 * 2 * 1.5 > 4000 px.
    const tall = { scale: 1.4, translateX: 0, translateY: -10000, containerWidth: 800, containerHeight: 2600 };
    expect(resolveDocumentRenderTarget(null, tall, layout, false).renderScale).toBe(1);
  });

  it('drops a held resolution when zooming out would exceed the native pixel cap', () => {
    const zoomed = resolveDocumentRenderTarget(null, at(-10000, 5), layout, false);
    expect(zoomed.renderScale).toBe(5);
    const out = resolveDocumentRenderTarget(zoomed, at(-5000, 1), layout, true);
    expect(out.renderScale).toBe(1);
  });

  it('never exceeds the native per-side pixel cap and stays inside the document', () => {
    for (const [translateY, scale] of [[0, 1], [-1e6, 1], [1e6, 3], [-50000, 5]] as const) {
      const target = resolveDocumentRenderTarget(null, at(translateY, scale), layout, false);
      const rect = rectOf(target);
      const px = 2 * target.renderScale;
      expect((rect.bottom - rect.top) * px).toBeLessThanOrEqual(4000.5);
      expect((rect.right - rect.left) * px).toBeLessThanOrEqual(4000.5);
      expect(target.topRatio).toBeGreaterThanOrEqual(0);
      expect(target.topRatio + target.heightRatio).toBeLessThanOrEqual(1 + 1e-9);
      expect(target.leftRatio + target.widthRatio).toBeLessThanOrEqual(1 + 1e-9);
    }
  });

  it('re-resolves when added pages stretch a reused target past the cap', () => {
    const small = { ...layout, pageCount: 2 };
    const first = resolveDocumentRenderTarget(null, at(-500), small, false);
    const grown = resolveDocumentRenderTarget(first, at(-500), { ...small, pageCount: 4 }, false);
    expect(grown).not.toBe(first);
    const rect = rectOf(grown, 4000);
    expect((rect.bottom - rect.top) * 2).toBeLessThanOrEqual(4000.5);
  });

  it('stays finite and stable for degenerate layout or transform values', () => {
    const bad = { pageWidth: Number.NaN, pageHeight: 0, pageCount: Number.POSITIVE_INFINITY, contentPadding: Number.NaN,
      pixelRatio: Number.NaN, maxRenderScale: Number.NaN };
    const transform = { scale: Number.NaN, translateX: Number.NaN, translateY: Number.NaN, containerWidth: 0, containerHeight: 0 };
    const first = resolveDocumentRenderTarget(null, transform, bad, false);
    for (const value of Object.values(first)) expect(Number.isFinite(value)).toBe(true);
    expect(resolveDocumentRenderTarget(first, transform, bad, false)).toBe(first);
  });
});
