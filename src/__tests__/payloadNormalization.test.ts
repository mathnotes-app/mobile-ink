/**
 * Tests for normalizePagePayloadForNativeLoad.
 *
 * Native loads must only accept object payloads with a pages map. Everything
 * else is either normalized to a blank notebook or rejected as unsafe.
 */

import { normalizePagePayloadForNativeLoad } from '../payload';

const BLANK_PAGE_PAYLOAD = '{"pages":{}}';

describe('normalizePagePayloadForNativeLoad', () => {
  describe('blank payloads', () => {
    it.each([
      ['null', null],
      ['undefined', undefined],
      ['empty string', ''],
      ['whitespace only', '   \n\t  '],
    ] as const)('treats %s as a valid blank load', (_label, input) => {
      const result = normalizePagePayloadForNativeLoad(input);

      expect(result).toEqual({
        isValid: true,
        normalizedPayload: BLANK_PAGE_PAYLOAD,
        reasonCode: 'blank_payload',
      });
    });
  });

  describe('invalid JSON and non-object roots', () => {
    it('rejects unparseable JSON as unsafe', () => {
      const result = normalizePagePayloadForNativeLoad('{not-json');

      expect(result.isValid).toBe(false);
      expect(result.normalizedPayload).toBe(BLANK_PAGE_PAYLOAD);
      expect(result.reasonCode).toBe('json_parse_failed');
    });

    it.each([
      ['array root', '[]'],
      ['array with objects', '[{"pages":{}}]'],
      ['string root', '"pages"'],
      ['number root', '42'],
      ['boolean root', 'true'],
      ['null root', 'null'],
    ])('rejects %s (payload_not_object)', (_label, input) => {
      const result = normalizePagePayloadForNativeLoad(input);

      expect(result.isValid).toBe(false);
      expect(result.normalizedPayload).toBe(BLANK_PAGE_PAYLOAD);
      expect(result.reasonCode).toBe('payload_not_object');
    });
  });

  describe('missing or invalid pages', () => {
    it.each([
      ['missing pages key', '{"version":"1.0"}'],
      ['pages null', '{"pages":null}'],
      ['pages array', '{"pages":[]}'],
      ['pages string', '{"pages":"nope"}'],
      ['pages number', '{"pages":1}'],
    ])('normalizes %s to blank with missing_pages', (_label, input) => {
      const result = normalizePagePayloadForNativeLoad(input);

      // Safe to load as blank; not a hard reject (legacy / empty notebooks).
      expect(result.isValid).toBe(true);
      expect(result.normalizedPayload).toBe(BLANK_PAGE_PAYLOAD);
      expect(result.reasonCode).toBe('missing_pages');
    });
  });

  describe('valid payloads', () => {
    it('accepts object payload with empty pages map', () => {
      const input = '{"pages":{}}';
      const result = normalizePagePayloadForNativeLoad(input);

      expect(result.isValid).toBe(true);
      expect(result.normalizedPayload).toBe(input);
      expect(result.reasonCode).toBeUndefined();
    });

    it('accepts object payload with page entries and preserves original text', () => {
      const input =
        '{"pages":{"page-1":{"strokes":[]}},"version":"1.0"}';
      const result = normalizePagePayloadForNativeLoad(input);

      expect(result.isValid).toBe(true);
      expect(result.normalizedPayload).toBe(input);
      expect(result.reasonCode).toBeUndefined();
    });

    it('trims surrounding whitespace but keeps the JSON body', () => {
      const body = '{"pages":{"a":{}}}';
      const result = normalizePagePayloadForNativeLoad(`  \n${body}\t`);

      expect(result.isValid).toBe(true);
      expect(result.normalizedPayload).toBe(body);
      expect(result.reasonCode).toBeUndefined();
    });
  });

  describe('safety invariants', () => {
    it('never returns a non-blank normalized payload when isValid is false', () => {
      const badInputs = [
        '{',
        '[]',
        'null',
        '1',
        '"x"',
        'true',
        'not json at all',
      ];

      for (const input of badInputs) {
        const result = normalizePagePayloadForNativeLoad(input);
        if (!result.isValid) {
          expect(result.normalizedPayload).toBe(BLANK_PAGE_PAYLOAD);
        }
      }
    });
  });
});
