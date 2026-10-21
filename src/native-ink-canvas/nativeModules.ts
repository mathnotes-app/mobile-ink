import {
  NativeModules,
  Platform,
  requireNativeComponent,
  UIManager,
} from "react-native";
import type { InkDisplayAppearance } from '../displayAppearance';

const COMPONENT_NAME = "MobileInkCanvasView";

export const MobileInkCanvasViewManager = Platform.OS === "ios"
  ? NativeModules.MobileInkCanvasViewManager
  : null;
export const MobileInkModule = Platform.OS === "android"
  ? NativeModules.MobileInkModule
  : null;
export const MobileInkBridge = Platform.OS === "ios"
  ? NativeModules.MobileInkBridge
  : null;

if (__DEV__) {
  if (Platform.OS === "ios" && !MobileInkCanvasViewManager) {
    console.warn("[NativeInkCanvas] MobileInkCanvasViewManager not found in NativeModules. Drawing serialization may not work.");
  }
  if (Platform.OS === "android" && !MobileInkModule) {
    console.warn("[NativeInkCanvas] MobileInkModule not found in NativeModules. Drawing serialization may not work.");
  }
}

const LINKING_ERROR =
  "The package 'MobileInkCanvasView' doesn't seem to be linked. Make sure: \n\n" +
  Platform.select({ ios: "- You have run 'pod install'\n", default: "" }) +
  "- You rebuilt the app after installing the package\n" +
  "- You are not using Expo Go\n";

const mobileInkCanvasViewConfig = UIManager.getViewManagerConfig(COMPONENT_NAME) as
  | { NativeProps?: Record<string, unknown> }
  | null;

export const supportsRenderBackendProp =
  !!mobileInkCanvasViewConfig?.NativeProps &&
  Object.prototype.hasOwnProperty.call(
    mobileInkCanvasViewConfig.NativeProps,
    "renderBackend",
  );

const backgroundConfig = Platform.OS === 'ios'
  ? UIManager.getViewManagerConfig('MobileInkBackgroundView') as { NativeProps?: Record<string, unknown> } | null
  : null;

export const supportsInkDisplayAppearance = !!mobileInkCanvasViewConfig?.NativeProps?.displayAppearance &&
  (Platform.OS !== 'ios' || !!backgroundConfig?.NativeProps?.displayAppearance);

/** Keep document ink and paper readable when JavaScript runs on an older binary. */
export function resolveInkDisplayAppearance(requested: InkDisplayAppearance): InkDisplayAppearance {
  'worklet';
  return requested === 'dark' && supportsInkDisplayAppearance ? 'dark' : 'light';
}

export const MobileInkCanvasViewNative =
  mobileInkCanvasViewConfig != null
    ? requireNativeComponent<any>(COMPONENT_NAME)
    : () => {
        throw new Error(LINKING_ERROR);
      };
