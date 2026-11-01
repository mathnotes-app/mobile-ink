import React from 'react';
import { Image, View } from 'react-native';
import { fireEvent, render } from '@testing-library/react-native';
import { Skia, useImage } from '@shopify/react-native-skia';
import { InkDisplayImage } from '../InkDisplayImage';

jest.mock('@shopify/react-native-skia', () => {
  const React = require('react');
  const { View } = require('react-native');
  return {
    Canvas: (props: any) => React.createElement(View, { ...props, testID: 'display-canvas' }),
    Image: (props: any) => React.createElement(View, { ...props, testID: 'diagram-pixels' }),
    RuntimeShader: () => null,
    useImage: jest.fn(),
    Skia: { RuntimeEffect: { Make: jest.fn() } },
  };
});
jest.mock('react-native-reanimated', () => ({
  useSharedValue: (value: unknown) => ({ value }),
  useDerivedValue: (get: () => unknown) => ({ value: get() }),
}));

beforeEach(() => {
  jest.clearAllMocks();
  (useImage as jest.Mock).mockReturnValue({ pixels: 'authored' });
  (Skia.RuntimeEffect.Make as jest.Mock).mockReturnValue({ program: 'display-only' });
});

it('uses the original image and load callback for authored appearance', () => {
  const ready = jest.fn();
  const screen = render(<InkDisplayImage uri="file:///diagram.png" onReady={ready} />);
  const image = screen.UNSAFE_getByType(Image);
  expect(image.props.source.uri).toBe('file:///diagram.png');
  fireEvent(image, 'load');
  expect(ready).toHaveBeenCalledTimes(1);
  expect(useImage).not.toHaveBeenCalled();
});

it('does not announce a dark diagram ready until its original pixels load', () => {
  const ready = jest.fn();
  (useImage as jest.Mock).mockReturnValue(null);
  const screen = render(<InkDisplayImage uri="file:///diagram.png" displayAppearance="dark" onReady={ready} />);
  expect(ready).not.toHaveBeenCalled();
  (useImage as jest.Mock).mockReturnValue({ pixels: 'authored' });
  screen.rerender(<InkDisplayImage uri="file:///diagram.png" displayAppearance="dark" onReady={ready} />);
  expect(ready).not.toHaveBeenCalled();
  const wrapper = screen.UNSAFE_getAllByType(View).find(view => view.props.onLayout);
  fireEvent(wrapper!, 'layout', { nativeEvent: { layout: { width: 140, height: 100 } } });
  expect(ready).toHaveBeenCalledTimes(1);
  expect(screen.getByTestId('diagram-pixels').props.width).toBe(140);
  expect(screen.getByTestId('diagram-pixels').props.height).toBe(100);
  expect(useImage).toHaveBeenLastCalledWith('file:///diagram.png', expect.any(Function));
});

it('reports decode failure without exposing a private image URI', () => {
  const failed = jest.fn();
  const screen = render(<InkDisplayImage uri="data:image/png;base64,private-pixels" onError={failed} />);
  fireEvent(screen.UNSAFE_getByType(Image), 'error', { nativeEvent: { error: 'private-pixels' } });
  expect(failed.mock.calls[0][0].message).toBe('Could not load the rendered diagram');
});

it('reports a shader failure and keeps the authored image readable', () => {
  const error = jest.spyOn(console, 'error').mockImplementation(() => {});
  try {
    const failed = jest.fn();
    (Skia.RuntimeEffect.Make as jest.Mock).mockReturnValue(null);
    const screen = render(<InkDisplayImage uri="file:///diagram.png" displayAppearance="dark" onError={failed} />);
    expect(failed).toHaveBeenCalledWith(expect.any(Error));
    expect(screen.UNSAFE_getByType(Image).props.source.uri).toBe('file:///diagram.png');
  } finally { error.mockRestore(); }
});
