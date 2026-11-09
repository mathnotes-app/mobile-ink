import React from 'react';
import { render } from '@testing-library/react-native';
import { StyleSheet } from 'react-native';
import { PageBreaks, pageBreakRange } from '../PageStack';
import type { NotebookPage } from '../../types';

jest.mock('../../NativeInkPageBackground', () => 'NativeInkPageBackground');

const pages = Array.from({ length: 100 }, (_, index) => ({
  id: `page-${index}`, title: '', rotation: 0, data: '{"pages":{}}',
})) as NotebookPage[];

it('keeps all potentially visible dividers at the minimum zoom with pan runway', () => {
  const range = pageBreakRange(100, 50, 1061, 1200, 0.25);
  // Even at 25% zoom a 1200-point viewport spans fewer than five pages.
  expect(range.first).toBeLessThanOrEqual(48);
  expect(range.last).toBeGreaterThanOrEqual(53);
  expect(range.last - range.first + 1).toBeLessThan(25);
  expect(pageBreakRange(100, 0, 1061, 1200, 0.25).first).toBe(1);
  expect(pageBreakRange(100, 99, 1061, 1200, 0.25).last).toBe(99);
  const tallWindow = pageBreakRange(100, 50, 1061, 8000, 0.25);
  expect(tallWindow.first).toBeLessThanOrEqual(35);
  expect(tallWindow.last).toBeGreaterThanOrEqual(65);
});

it('renders correctly numbered dividers when the visible page changes', () => {
  const view = render(<PageBreaks pages={pages} pageHeight={1061} visiblePageIndex={0}
    viewportHeight={1200} minimumScale={0.25} />);
  expect(view.getByTestId('ink-page-boundary-1')).toBeTruthy();
  expect(view.queryByTestId('ink-page-boundary-50')).toBeNull();
  view.rerender(<PageBreaks pages={pages} pageHeight={1061} visiblePageIndex={50}
    viewportHeight={1200} minimumScale={0.25} />);
  expect(view.getByTestId('ink-page-boundary-50')).toBeTruthy();
  expect(StyleSheet.flatten(view.getByTestId('ink-page-boundary-50').props.style).top)
    .toBeCloseTo(50 * 1061 - StyleSheet.hairlineWidth / 2);
  expect(view.queryByTestId('ink-page-boundary-1')).toBeNull();
});

it('keeps every divider when reliable viewport information is unavailable', () => {
  expect(pageBreakRange(100, 0, 1061, 1200, 0)).toEqual({ first: 1, last: 99 });
  expect(pageBreakRange(100, undefined, 1061, 1200, 0.25)).toEqual({ first: 1, last: 99 });
  expect(pageBreakRange(1, 0, 1061, 1200, 0.25)).toEqual({ first: 1, last: 0 });
});
