import React, { useCallback, useEffect, useMemo, useState } from 'react';
import { Image as NativeImage, View, StyleSheet, type StyleProp, type ImageStyle } from 'react-native';
import { Canvas, Image, RuntimeShader, Skia, useImage } from '@shopify/react-native-skia';
import { DARK_INK_IMAGE_SHADER, type InkDisplayAppearance } from './displayAppearance';

export type InkDisplayImageProps = {
  uri: string;
  style?: StyleProp<ImageStyle>;
  displayAppearance?: InkDisplayAppearance;
  onReady?: () => void;
  onError?: (error: Error) => void;
};

/** For rendered ink/diagrams. Photos should retain their authored appearance. */
export function InkDisplayImage(props: InkDisplayImageProps) {
  return props.displayAppearance === 'dark' ? <DarkImage {...props} /> : <AuthoredImage {...props} />;
}

function AuthoredImage({ uri, style, onReady, onError }: InkDisplayImageProps) {
  return <NativeImage source={{ uri }} style={style ?? StyleSheet.absoluteFillObject} resizeMode="contain" onLoad={onReady}
    onError={() => reportImageError(onError)} />;
}

function reportImageError(onError?: (error: Error) => void) {
  // Native decoder errors may embed the entire data URI of a private diagram.
  const error = new Error('Could not load the rendered diagram');
  if (onError) onError(error);
  else console.error('[MobileInk]', error);
}

function DarkImage(props: InkDisplayImageProps) {
  const { uri, style, onReady, onError } = props;
  const readError = useCallback(() => reportImageError(onError), [onError]);
  const image = useImage(uri, readError);
  const effect = useMemo(() => Skia.RuntimeEffect.Make(DARK_INK_IMAGE_SHADER), []);
  const [size, setSize] = useState({ width: 0, height: 0 });
  useEffect(() => {
    if (effect && image && size.width > 0 && size.height > 0) onReady?.();
  }, [effect, image, size, onReady]);
  useEffect(() => {
    if (!effect) {
      const error = new Error('Could not initialize diagram display contrast');
      console.error('[MobileInk]', error);
      onError?.(error);
    }
  }, [effect, onError]);
  if (!effect) return <View style={[style ?? StyleSheet.absoluteFillObject, { backgroundColor: '#FFFFFF' }]}>
    <AuthoredImage {...props} style={StyleSheet.absoluteFillObject} />
  </View>;
  // Skia 2.2's onSize registration dereferences an unattached Fabric view.
  // Measure the outer RN view instead; pan/zoom transforms do not relayout it.
  return <View style={style ?? StyleSheet.absoluteFillObject} onLayout={event => {
    const { width, height } = event.nativeEvent.layout;
    setSize(current => current.width === width && current.height === height ? current : { width, height });
  }}><Canvas style={StyleSheet.absoluteFillObject} colorSpace="srgb">
    <Image image={image} x={0} y={0} width={size.width} height={size.height} fit="contain">
      <RuntimeShader source={effect} />
    </Image>
  </Canvas></View>;
}
