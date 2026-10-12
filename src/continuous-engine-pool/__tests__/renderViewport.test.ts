import { getPageRenderViewport } from "../renderViewport";

const transform = {
  scale: 2, translateX: 0, translateY: 0,
  containerWidth: 1000, containerHeight: 800,
};

describe("centered page render viewport", () => {
  it("sharpens the centered page region, not the container-relative region", () => {
    expect(getPageRenderViewport(transform, 0, 600, 1000, 20)).toEqual({
      leftRatio: 50 / 600,
      topRatio: 180 / 1000,
      widthRatio: 500 / 600,
      heightRatio: 400 / 1000,
      intersectsViewport: true,
    });
  });

  it("handles a page wider than its viewport and horizontal panning", () => {
    const result = getPageRenderViewport({
      ...transform, containerWidth: 400, translateX: -100,
    }, 0, 800, 1000, 0);
    // Visible container coordinates [150,350], page starts at -200.
    expect(result.leftRatio).toBe(350 / 800);
    expect(result.widthRatio).toBe(200 / 800);
  });

  it("projects a zoomed viewport straddling two pages into each native canvas", () => {
    const crossing = { ...transform, translateY: -1200 };
    const first = getPageRenderViewport(crossing, 0, 600, 1000, 20);
    const second = getPageRenderViewport(crossing, 1, 600, 1000, 20);
    expect(first.topRatio).toBe(0.78);
    expect(first.heightRatio).toBe(0.22);
    expect(second.topRatio).toBe(0);
    expect(second.heightRatio).toBe(0.18);
    expect(first.intersectsViewport && second.intersectsViewport).toBe(true);
  });

  it("does not allocate sharpened surfaces for offscreen pages", () => {
    expect(getPageRenderViewport(transform, 3, 600, 1000, 20).intersectsViewport).toBe(false);
  });

  it("keeps full-page rendering before viewport measurement is available", () => {
    expect(getPageRenderViewport(null, null, 600, 1000, 20)).toEqual({
      leftRatio: 0, topRatio: 0, widthRatio: 1, heightRatio: 1,
      intersectsViewport: true,
    });
  });
});
