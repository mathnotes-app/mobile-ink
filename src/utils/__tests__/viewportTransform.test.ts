import { getVisibleContentRect } from "../viewportTransform";

describe("getVisibleContentRect", () => {
  it("matches top-left translation at 1x scale", () => {
    expect(getVisibleContentRect({
      scale: 1,
      translateX: -40,
      translateY: -120,
      containerWidth: 600,
      containerHeight: 800,
    })).toEqual({
      left: 40,
      top: 120,
      right: 640,
      bottom: 920,
      width: 600,
      height: 800,
    });
  });

  it("accounts for the viewport-center transform origin while zoomed", () => {
    expect(getVisibleContentRect({
      scale: 2,
      translateX: 0,
      translateY: 0,
      containerWidth: 400,
      containerHeight: 400,
    })).toEqual({
      left: 100,
      top: 100,
      right: 300,
      bottom: 300,
      width: 200,
      height: 200,
    });
  });
});
