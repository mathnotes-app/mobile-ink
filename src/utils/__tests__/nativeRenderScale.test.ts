import {
  getNativeRenderScaleBudget,
  quantizeNativeRenderScale,
} from "../nativeRenderScale";

describe("native render scale budgeting", () => {
  it("caps default iPad page render scale to the 2.5x bucket", () => {
    const budget = getNativeRenderScaleBudget(820, 1061, 2);

    expect(budget).toBeGreaterThan(2.5);
    expect(budget).toBeLessThan(3);
    expect(quantizeNativeRenderScale(5, budget)).toBe(2.5);
  });

  it("never chooses a bucket above the requested zoom or pixel budget", () => {
    expect(quantizeNativeRenderScale(2.4, 5)).toBe(2);
    expect(quantizeNativeRenderScale(5, 2.2)).toBe(2);
  });

  it("falls back to base scale for invalid page geometry", () => {
    expect(getNativeRenderScaleBudget(0, 1061, 2)).toBe(1);
    expect(quantizeNativeRenderScale(Number.NaN, 5)).toBe(1);
  });
});
