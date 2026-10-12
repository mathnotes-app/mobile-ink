import { act, renderHook } from '@testing-library/react-native';
import type { SharedValue } from 'react-native-reanimated';
import { useViewportTransition } from '../useViewportTransition';

const mockCompletions: Array<(finished: boolean) => void> = [];
jest.mock('react-native-reanimated', () => ({
  cancelAnimation: jest.fn(),
  runOnJS: (callback: Function) => callback,
  withTiming: (value: number, _options: unknown, completion: (finished: boolean) => void) => {
    mockCompletions.push(completion);
    return value;
  },
}));

const shared = <T>(value: T) => ({ value } as SharedValue<T>);
function setup() {
  const values = {
    scale: shared(1), translateX: shared(0), translateY: shared(0),
    savedScale: shared(1), savedTranslateX: shared(0), savedTranslateY: shared(0),
    containerWidth: shared(800), containerHeight: shared(1000),
    isGesturingRef: shared(false), isDecayingX: shared(false), isDecayingY: shared(false),
    isClampingX: shared(false), isClampingY: shared(false), isMotionActive: shared(false),
  };
  const events: unknown[] = [];
  const motion = (moving: boolean) => events.push(moving);
  const transform = (value: unknown) => events.push(value);
  const hook = renderHook(() => useViewportTransition(values, motion, transform));
  return { ...hook, values, events };
}
const destination = { scale: 2, translateX: 20, translateY: -99000 };
const reported = { ...destination, containerWidth: 800, containerHeight: 1000 };

beforeEach(() => { mockCompletions.length = 0; });

it('reports an immediate destination before announcing that motion ended', () => {
  const { result, values, events } = setup();
  act(() => result.current(destination, false));
  expect(events).toEqual([true, reported, false]);
  expect(values.savedTranslateY.value).toBe(-99000);
  expect(values.translateY.value).toBe(-99000);
  expect(values.isMotionActive.value).toBe(false);
});

it('waits for all axes, then flushes the destination regardless of notification throttling', () => {
  const { result, events } = setup();
  act(() => result.current(destination, true));
  act(() => { mockCompletions[0](true); mockCompletions[2](true); });
  expect(events).toEqual([true]);
  act(() => mockCompletions[1](true));
  expect(events).toEqual([true, reported, false]);
});

it('does not let a superseded animation unlock a newer page jump', () => {
  const { result, events } = setup();
  act(() => result.current(destination, true));
  act(() => result.current({ ...destination, translateY: -500 }, true));
  act(() => mockCompletions.slice(0, 3).forEach(callback => callback(true)));
  expect(events).toEqual([true, true]);
  act(() => mockCompletions.slice(3).forEach(callback => callback(true)));
  expect(events).toEqual([true, true, { ...reported, translateY: -500 }, false]);
});

it('leaves an interrupting gesture in control of motion and its destination', () => {
  const { result, values, events } = setup();
  act(() => result.current(destination, true));
  values.isGesturingRef.value = true;
  act(() => mockCompletions.forEach(callback => callback(true)));
  expect(events).toEqual([true]);
});

it('does not report a destination for cancelled animations or an unmounted viewport', () => {
  const { result, unmount, events } = setup();
  act(() => result.current(destination, true));
  act(() => mockCompletions.forEach(callback => callback(false)));
  expect(events).toEqual([true]);
  unmount();
  act(() => mockCompletions.forEach(callback => callback(true)));
  expect(events).toEqual([true]);
});

it('ignores queued completions after an interrupting gesture has already settled', () => {
  const { result, values, events } = setup();
  act(() => result.current(destination, true));
  values.translateY.value = -1200;
  values.isMotionActive.value = false;
  act(() => mockCompletions.forEach(callback => callback(true)));
  expect(events).toEqual([true]);
  expect(values.translateY.value).toBe(-1200);
});
