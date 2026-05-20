import React from "react";
import { render } from "@testing-library/react-native";
import { NativeInkCanvas } from "../NativeInkCanvas";

const mockNativeCanvasProps: any[] = [];

jest.mock("../native-ink-canvas/nativeModules", () => {
  const React = require("react");
  const { View } = require("react-native");

  return {
    MobileInkCanvasViewManager: null,
    MobileInkModule: null,
    MobileInkBridge: null,
    supportsRenderBackendProp: true,
    MobileInkCanvasViewNative: React.forwardRef((props: any, ref: any) => {
      mockNativeCanvasProps.push(props);
      React.useImperativeHandle(ref, () => ({
        setNativeProps: jest.fn(),
      }), []);
      return <View testID="mock-native-ink-canvas" />;
    }),
  };
});

describe("NativeInkCanvas", () => {
  beforeEach(() => {
    mockNativeCanvasProps.length = 0;
  });

  it("maps JS selection changes to the native ink selection event prop", () => {
    const onSelectionChange = jest.fn();

    render(<NativeInkCanvas onSelectionChange={onSelectionChange} />);

    expect(mockNativeCanvasProps[0].onInkSelectionChange).toBe(onSelectionChange);
    expect(mockNativeCanvasProps[0].onSelectionChange).toBeUndefined();
  });
});
