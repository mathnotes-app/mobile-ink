import {
  getRevealTargetScreenY,
  getRevealTranslateY,
  getVisibleContentRect,
} from "../viewportTransform";

describe("reveal position transform", () => {
  it("places content at the target screen position at 1x scale", () => {
    expect(getRevealTranslateY(400, 210, 1, 600)).toBe(-190);
  });

  it("accounts for the viewport-center transform origin while zoomed", () => {
    const containerHeight = 600;
    const contentY = 400;
    const scale = 2;
    const targetScreenY = 210;
    const translateY = getRevealTranslateY(
      contentY,
      targetScreenY,
      scale,
      containerHeight,
    );
    const originY = containerHeight / 2;
    const actualScreenY = originY + translateY + scale * (contentY - originY);

    expect(actualScreenY).toBe(targetScreenY);
  });

  it("uses the keyboard-resized container height for the safe target", () => {
    expect(getRevealTargetScreenY(400)).toBe(140);
    expect(getRevealTargetScreenY(800)).toBe(220);
  });
});

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
