function capability(canvas: boolean, background: boolean, platform = 'ios') {
  jest.resetModules();
  jest.doMock('react-native', () => ({
    Platform: { OS: platform, select: () => '' },
    NativeModules: { MobileInkCanvasViewManager: {}, MobileInkModule: {}, MobileInkBridge: {} },
    requireNativeComponent: () => 'NativeCanvas',
    UIManager: { getViewManagerConfig: (name: string) => ({
      NativeProps: { displayAppearance: (name === 'MobileInkCanvasView' ? canvas : background) ? 'String' : undefined },
    }) },
  }));
  return require('../native-ink-canvas/nativeModules') as typeof import('../native-ink-canvas/nativeModules');
}

it('keeps authored paper and ink when an older canvas binary lacks contrast support', () => {
  expect(capability(false, true).resolveInkDisplayAppearance('dark')).toBe('light');
});

it('requires both iOS paper and ink to support dark display', () => {
  expect(capability(true, false).resolveInkDisplayAppearance('dark')).toBe('light');
});

it('enables dark display with a matching native binary and keeps light unchanged', () => {
  const supported = capability(true, true);
  expect(supported.resolveInkDisplayAppearance('dark')).toBe('dark');
  expect(supported.resolveInkDisplayAppearance('light')).toBe('light');
});

it('does not require the iOS paper view on Android', () => {
  expect(capability(true, false, 'android').resolveInkDisplayAppearance('dark')).toBe('dark');
});
