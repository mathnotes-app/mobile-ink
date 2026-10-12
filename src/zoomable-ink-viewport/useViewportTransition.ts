import { createTransitionCompletion } from './transitionCompletion';
import { useCallback, useEffect, useMemo, useRef } from 'react';
import { cancelAnimation, runOnJS, withTiming } from 'react-native-reanimated';
import type { SharedValue } from 'react-native-reanimated';
import type { ZoomableInkViewportProps } from './types';

type NumericKey = 'scale' | 'translateX' | 'translateY' | 'savedScale' |
  'savedTranslateX' | 'savedTranslateY' | 'containerWidth' | 'containerHeight';
type MotionKey = 'isGesturingRef' | 'isDecayingX' | 'isDecayingY' |
  'isClampingX' | 'isClampingY' | 'isMotionActive';
type Values = { [K in NumericKey]: SharedValue<number> } &
  { [K in MotionKey]: SharedValue<boolean> };
type Transform = { scale: number; translateX: number; translateY: number };

/** Imperative jumps must trigger the same pool handoff as a finished gesture. */
export function useViewportTransition(
  values: Values,
  onMotionStateChange: ZoomableInkViewportProps['onMotionStateChange'],
  onTransformChange: ZoomableInkViewportProps['onTransformChange'],
) {
  const generation = useRef(0);
  const completionBridge = useMemo(createTransitionCompletion, []);
  const completeAxis = completionBridge.completeAxis;
  useEffect(() => () => { generation.current += 1; completionBridge.clear(); }, [completionBridge]);

  return useCallback((next: Transform, animated: boolean) => {
    const token = ++generation.current;
    completionBridge.clear();
    cancelAnimation(values.scale);
    cancelAnimation(values.translateX);
    cancelAnimation(values.translateY);
    values.isDecayingX.value = false;
    values.isDecayingY.value = false;
    values.isClampingX.value = false;
    values.isClampingY.value = false;
    values.isMotionActive.value = true;
    onMotionStateChange?.(true);

    const finish = () => {
      if (generation.current !== token || values.isGesturingRef.value ||
          values.isDecayingX.value || values.isDecayingY.value ||
          values.isClampingX.value || values.isClampingY.value) return;
      // A gesture can start and finish before queued JS completions arrive.
      // Never publish the old destination over its newer settled transform.
      if (values.scale.value !== next.scale ||
          values.translateX.value !== next.translateX ||
          values.translateY.value !== next.translateY) return;
      // Flush even if the last animation frame fell inside the JS notification
      // throttle. Consumers need the destination before releasing their lock.
      onTransformChange?.({ ...next,
        containerWidth: values.containerWidth.value,
        containerHeight: values.containerHeight.value,
      });
      values.isMotionActive.value = false;
      onMotionStateChange?.(false);
    };

    values.savedScale.value = next.scale;
    values.savedTranslateX.value = next.translateX;
    values.savedTranslateY.value = next.translateY;
    if (animated) {
      completionBridge.begin(token, 3, finish);
      const completion = (finished?: boolean) => {
        'worklet';
        runOnJS(completeAxis)(token, finished === true);
      };
      values.scale.value = withTiming(next.scale, { duration: 150 }, completion);
      values.translateX.value = withTiming(next.translateX, { duration: 150 }, completion);
      values.translateY.value = withTiming(next.translateY, { duration: 150 }, completion);
    } else {
      values.scale.value = next.scale;
      values.translateX.value = next.translateX;
      values.translateY.value = next.translateY;
      finish();
    }
  }, [values, onMotionStateChange, onTransformChange, completionBridge, completeAxis]);
}
