import {createTransitionCompletion} from '../transitionCompletion';

test('finishes once after all axes and ignores stale native callbacks', () => {
  const bridge = createTransitionCompletion();
  const old = jest.fn(), latest = jest.fn();
  const native = bridge.completeAxis;
  bridge.begin(1, 3, old);
  native(1);
  bridge.begin(2, 3, latest);
  native(1); native(1);
  native(2); native(2);
  expect(latest).not.toHaveBeenCalled();
  native(2); native(2);
  expect(latest).toHaveBeenCalledTimes(1);
  expect(old).not.toHaveBeenCalled();
});
test('clears pending consumers on disposal and before reentrant completion', () => {
  const bridge = createTransitionCompletion();
  const disposed = jest.fn();
  bridge.begin(1, 3, disposed);
  bridge.clear();
  bridge.completeAxis(1); bridge.completeAxis(1); bridge.completeAxis(1);
  expect(disposed).not.toHaveBeenCalled();
  const next = jest.fn();
  bridge.begin(2, 1, () => bridge.begin(3, 1, next));
  bridge.completeAxis(2); bridge.completeAxis(3);
  expect(next).toHaveBeenCalledTimes(1);
});

test('a cancelled axis releases the transition without publishing its destination', () => {
  const bridge = createTransitionCompletion();
  const finish = jest.fn();
  bridge.begin(1, 3, finish);
  bridge.completeAxis(1, false);
  bridge.completeAxis(1); bridge.completeAxis(1); bridge.completeAxis(1);
  expect(finish).not.toHaveBeenCalled();
});
