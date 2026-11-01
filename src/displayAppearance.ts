export type InkDisplayAppearance = 'light' | 'dark';

export const INK_PAPER_COLORS = { light: '#FFFFFF', dark: '#262626' } as const;

// Same transfer functions and lightness transform as the native display filter.
export const DARK_INK_IMAGE_SHADER = String.raw`
uniform shader image;
float3 toLinear(float3 c) {
  return mix(c / 12.92, pow((c + 0.055) / 1.055, float3(2.4)), step(float3(0.04045), c));
}
float3 toSrgb(float3 c) {
  return mix(c * 12.92, 1.055 * pow(c, float3(1.0 / 2.4)) - 0.055, step(float3(0.0031308), c));
}
half4 main(float2 p) {
  half4 color = image.eval(p);
  if (color.a <= 0.0001) return color;
  float3 rgb = toLinear(clamp(color.rgb / color.a, 0.0, 1.0));
  float shift = 1.0 - max(rgb.r, max(rgb.g, rgb.b)) - min(rgb.r, min(rgb.g, rgb.b));
  return half4((0.15 + 0.85 * toSrgb(clamp(rgb + shift, 0.0, 1.0))) * color.a, color.a);
}`;

/** Matches Skia's lightness inversion in linear RGB; authored values stay intact. */
export function inkDisplayColor(authored: string | null | undefined, appearance: InkDisplayAppearance, fallback = '#000000'): string {
  'worklet';
  const original = typeof authored === 'string' ? authored : fallback;
  if (appearance === 'light') return original;
  const source = original.trim();
  const name = source.toLowerCase();
  let hex = (name === 'black' ? '#000000' : name === 'white' ? '#FFFFFF' : source).replace(/^#/, '');
  const functional = source.match(/^rgba?\(([^)]+)\)$/i);
  if (functional) {
    const parts = functional[1]!.trim().split(/[\s,/]+/);
    if (parts.length !== 3 && parts.length !== 4) return original;
    const values = parts.map((part, index) => {
      const value = Number(part.endsWith('%') ? part.slice(0, -1) : part);
      const maximum = part.endsWith('%') ? 100 : index === 3 ? 1 : 255;
      return Math.round(Math.max(0, Math.min(1, value / maximum)) * 255);
    });
    if (values.some(value => !Number.isFinite(value))) return original;
    hex = values.map(value => value.toString(16).padStart(2, '0')).join('');
  }
  if (/^[\da-f]{3,4}$/i.test(hex)) hex = [...hex].map(value => value + value).join('');
  if (!/^[\da-f]{6}([\da-f]{2})?$/i.test(hex)) return original;
  const rgb = [0, 2, 4].map(offset => {
    const value = parseInt(hex.slice(offset, offset + 2), 16) / 255;
    return value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4;
  });
  const shift = 1 - Math.max(...rgb) - Math.min(...rgb);
  return '#' + rgb.map(value => {
    const linear = value + shift;
    const srgb = linear <= 0.0031308 ? 12.92 * linear : 1.055 * linear ** (1 / 2.4) - 0.055;
    return Math.round((0.15 + 0.85 * Math.max(0, Math.min(1, srgb))) * 255).toString(16).padStart(2, '0');
  }).join('') + hex.slice(6);
}
