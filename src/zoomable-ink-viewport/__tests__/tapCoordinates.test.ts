import {viewportPointToContent} from '../geometry';

describe.each([1, 2, 5])('viewport touch routing at %sx', scale => {
  it.each([[1024, 1366], [1366, 1024]])('inverts centered zoom and pan in a %s by %s viewport', (width, height) => {
    const tx = -180, ty = -870;
    for (const content of [{x: 0, y: 0}, {x: 370, y: 1040}, {x: 730, y: 2100}]) {
      const screenX = width / 2 + tx + scale * (content.x - width / 2);
      const screenY = height / 2 + ty + scale * (content.y - height / 2);
      const actual = viewportPointToContent(screenX, screenY, scale, tx, ty, width, height);
      expect(actual.x).toBeCloseTo(content.x);
      expect(actual.y).toBeCloseTo(content.y);
    }
  });
});
