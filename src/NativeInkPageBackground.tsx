import React from "react";
import { INK_PAPER_COLORS, type InkDisplayAppearance } from './displayAppearance';
import { resolveInkDisplayAppearance, supportsInkDisplayAppearance } from './native-ink-canvas/nativeModules';
import {
  Platform,
  StyleProp,
  UIManager,
  View,
  ViewStyle,
  requireNativeComponent,
} from "react-native";

export type NativeInkPageBackgroundProps = {
  style?: StyleProp<ViewStyle>;
  backgroundType?: "plain" | "lined" | "grid" | "dotted" | "graph" | "pdf" | string;
  pdfBackgroundUri?: string;
  displayAppearance?: InkDisplayAppearance;
};

const ComponentName = "MobileInkBackgroundView";

const MobileInkBackgroundViewNative =
  Platform.OS === "ios" &&
  UIManager.getViewManagerConfig(ComponentName) != null
    ? requireNativeComponent<NativeInkPageBackgroundProps>(ComponentName)
    : null;

export function NativeInkPageBackground({
  style,
  backgroundType = "plain",
  pdfBackgroundUri,
  displayAppearance: requestedAppearance = 'light',
}: NativeInkPageBackgroundProps) {
  const displayAppearance = resolveInkDisplayAppearance(requestedAppearance);
  if (MobileInkBackgroundViewNative) {
    return (
      <MobileInkBackgroundViewNative
        style={style}
        backgroundType={backgroundType}
        pdfBackgroundUri={pdfBackgroundUri}
        {...(supportsInkDisplayAppearance ? { displayAppearance } : {})}
      />
    );
  }

  return <View style={[style, { backgroundColor: INK_PAPER_COLORS[displayAppearance] }]} />;
}

export default NativeInkPageBackground;
