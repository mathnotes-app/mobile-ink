import type { ZoomableInkViewportProps } from './types';

export type ViewportCallbacks = Pick<ZoomableInkViewportProps,
  'onZoomChange' | 'onGestureStateChange' | 'onMotionStateChange' | 'onTransformChange' | 'onContentTap'>;

/** Keep native-held functions outside the render closure that owns notebook data. */
export function createViewportCallbacks() {
  let current: ViewportCallbacks | null = null;
  return {
    update(next: ViewportCallbacks | null) { current = next; },
    notifyZoomChange: (scale: number) => current?.onZoomChange?.(scale),
    notifyGestureStart: () => current?.onGestureStateChange?.(true),
    notifyGestureEnd: () => current?.onGestureStateChange?.(false),
    notifyMotionChange: (moving: boolean) => current?.onMotionStateChange?.(moving),
    notifyTransformChange: (scale: number, translateX: number, translateY: number,
      containerWidth: number, containerHeight: number) => current?.onTransformChange?.({
        scale, translateX, translateY, containerWidth, containerHeight,
      }),
    notifyContentTap: (locationX: number, locationY: number) => current?.onContentTap?.({
      nativeEvent: { locationX, locationY, isZoomableContentTap: true },
    }),
  };
}
