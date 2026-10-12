import { trimIfNeeded } from '../trimIfNeeded';

describe('trimIfNeeded', () => {
  it.each([undefined, null, '', ' ', '\t\n', '\uFEFF', '\u00a0', '\u2003'])('handles empty/whitespace input %p', value => {
    expect(trimIfNeeded(value)).toBe('');
  });

  it.each([' plain ', '\tplain', 'plain\n', '\uFEFFplain\u00a0', '\u2003plain\u2029', 'a\n b', '\u200bplain\u200b'])('preserves trim semantics for %p', value => {
    expect(trimIfNeeded(value)).toBe(value.trim());
  });

  it('does not call trim for a large already-trimmed notebook', () => {
    const data = JSON.stringify({ pages: [{ data: 'a'.repeat(2_000_000), title: 'Math — notes' }] });
    const trim = jest.spyOn(String.prototype, 'trim');
    try {
      const result = trimIfNeeded(data);
      expect(trim).not.toHaveBeenCalled();
      expect(result).toBe(data);
    } finally { trim.mockRestore(); }
  });
});
