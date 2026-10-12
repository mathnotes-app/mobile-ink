const WHITESPACE = /\s/u;

/**
 * Hermes can copy an external string even when trim removes nothing. Notebook
 * bodies are often tens of MB; inspect their boundaries before asking for a copy.
 * Use JavaScript's whitespace class to preserve trim's Unicode/BOM semantics.
 */
export function trimIfNeeded(value: string | null | undefined): string {
  if (!value) return '';
  if (!WHITESPACE.test(value[0]) && !WHITESPACE.test(value[value.length - 1])) return value;
  return value.trim();
}
