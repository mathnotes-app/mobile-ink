import { inkDisplayColor } from '../displayAppearance';

it('leaves authored colors unchanged in light appearance', () => {
  for (const color of ['black', '#12345678', '#ABC', 'rgba(0,0,0,.5)']) {
    expect(inkDisplayColor(color, 'light')).toBe(color);
  }
});

it.each([
  ['black', '#ffffff'], ['white', '#262626'], ['#0008', '#ffffff88'],
  ['#ff0000', '#ff2626'], ['#336699', '#dde9fc'], ['#808080', '#e9e9e9'],
  ['rgba(0, 0, 0, 0.5)', '#ffffff80'], ['rgb(0% 0% 0% / 50%)', '#ffffff80'],
])('adapts %s through lightness while preserving hue and alpha', (authored, displayed) => {
  expect(inkDisplayColor(authored, 'dark')).toBe(displayed);
});

it('retains unsupported dynamic colors instead of corrupting them', () => {
  expect(inkDisplayColor('transparent', 'dark')).toBe('transparent');
  expect(inkDisplayColor('constructor', 'dark')).toBe('constructor');
  expect(inkDisplayColor('  #000000  ', 'dark')).toBe('#ffffff');
});

it('uses explicit semantic defaults for missing imported colors', () => {
  expect(inkDisplayColor(undefined, 'dark')).toBe('#ffffff');
  expect(inkDisplayColor(null, 'light')).toBe('#000000');
  expect(inkDisplayColor(undefined, 'dark', 'transparent')).toBe('transparent');
});
