export type ViewportTransformLike = {
  scale: number;
  translateX: number;
  translateY: number;
  containerWidth: number;
  containerHeight: number;
};

export type VisibleContentRect = {
  left: number;
  top: number;
  right: number;
  bottom: number;
  width: number;
  height: number;
};

const toFiniteNumber = (value: number, fallback: number) => (
  Number.isFinite(value) ? value : fallback
);

export const getRevealTargetScreenY = (containerHeight: number): number => {
  const resolvedContainerHeight = Math.max(
    0,
    toFiniteNumber(containerHeight, 0),
  );
  return Math.min(220, Math.max(96, resolvedContainerHeight * 0.35));
};

export const getRevealTranslateY = (
  contentY: number,
  targetScreenY: number,
  scale: number,
  containerHeight: number,
): number => {
  const resolvedContentY = toFiniteNumber(contentY, 0);
  const resolvedTargetScreenY = toFiniteNumber(targetScreenY, 0);
  const resolvedScale = Math.max(0.0001, toFiniteNumber(scale, 1));
  const resolvedContainerHeight = Math.max(
    0,
    toFiniteNumber(containerHeight, 0),
  );
  const originY = resolvedContainerHeight / 2;

  return (
    resolvedTargetScreenY -
    originY -
    resolvedScale * (resolvedContentY - originY)
  );
};

export const getVisibleContentRect = (
  transform: ViewportTransformLike,
): VisibleContentRect => {
  const scale = Math.max(0.0001, toFiniteNumber(transform.scale, 1));
  const containerWidth = Math.max(0, toFiniteNumber(transform.containerWidth, 0));
  const containerHeight = Math.max(0, toFiniteNumber(transform.containerHeight, 0));
  const translateX = toFiniteNumber(transform.translateX, 0);
  const translateY = toFiniteNumber(transform.translateY, 0);
  const originX = containerWidth / 2;
  const originY = containerHeight / 2;

  const left = originX + ((0 - originX - translateX) / scale);
  const top = originY + ((0 - originY - translateY) / scale);
  const right = originX + ((containerWidth - originX - translateX) / scale);
  const bottom = originY + ((containerHeight - originY - translateY) / scale);

  const normalizedLeft = Math.min(left, right);
  const normalizedTop = Math.min(top, bottom);
  const normalizedRight = Math.max(left, right);
  const normalizedBottom = Math.max(top, bottom);

  return {
    left: normalizedLeft,
    top: normalizedTop,
    right: normalizedRight,
    bottom: normalizedBottom,
    width: Math.max(0, normalizedRight - normalizedLeft),
    height: Math.max(0, normalizedBottom - normalizedTop),
  };
};
