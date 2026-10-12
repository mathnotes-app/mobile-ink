import {createViewportCallbacks} from '../viewportCallbacks';

test('native-held callback uses the latest committed consumer and releases it on disposal', () => {
  const bridge = createViewportCallbacks();
  const nativeCallback = bridge.notifyTransformChange;
  const oldConsumer = jest.fn();
  const newConsumer = jest.fn();
  bridge.update({onTransformChange: oldConsumer});
  nativeCallback(2, 10, 20, 500, 700);
  bridge.update({onTransformChange: newConsumer});
  nativeCallback(3, 11, 21, 500, 700);
  expect(oldConsumer).toHaveBeenCalledTimes(1);
  expect(newConsumer).toHaveBeenCalledWith({scale: 3, translateX: 11, translateY: 21,
    containerWidth: 500, containerHeight: 700});
  bridge.update(null);
  nativeCallback(4, 12, 22, 500, 700);
  expect(newConsumer).toHaveBeenCalledTimes(1);
});

test('forwards gesture, zoom, motion, and content events, then ignores queued events after unmount', () => {
  const bridge = createViewportCallbacks();
  const onZoomChange = jest.fn(), onGestureStateChange = jest.fn();
  const onMotionStateChange = jest.fn(), onContentTap = jest.fn();
  bridge.update({onZoomChange, onGestureStateChange, onMotionStateChange, onContentTap});
  bridge.notifyZoomChange(2); bridge.notifyGestureStart(); bridge.notifyGestureEnd();
  bridge.notifyMotionChange(true); bridge.notifyContentTap(10, 20);
  expect(onZoomChange).toHaveBeenCalledWith(2);
  expect(onGestureStateChange.mock.calls).toEqual([[true], [false]]);
  expect(onMotionStateChange).toHaveBeenCalledWith(true);
  expect(onContentTap).toHaveBeenCalledWith({nativeEvent: {locationX: 10, locationY: 20, isZoomableContentTap: true}});
  bridge.update(null);
  bridge.notifyZoomChange(3); bridge.notifyGestureStart(); bridge.notifyGestureEnd();
  bridge.notifyMotionChange(false); bridge.notifyContentTap(30, 40);
  expect(onZoomChange).toHaveBeenCalledTimes(1);
  expect(onGestureStateChange).toHaveBeenCalledTimes(2);
  expect(onMotionStateChange).toHaveBeenCalledTimes(1);
  expect(onContentTap).toHaveBeenCalledTimes(1);
});
