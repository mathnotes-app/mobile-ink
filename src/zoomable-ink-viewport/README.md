# Shared notebook viewport

`ZoomableInkViewport` owns viewport transforms and delegates gestures to
`useZoomableViewportGestures`. Both continuous and paged notebook consumers can
use the same bounds, touch exclusions, and viewport notifications.

`initialScale` sets only the mount-time scale, clamped to the configured limits.
Its default remains 1, and reset methods return to 1. This supports apps that
open new notes at a different zoom without changing existing consumers.

`useViewportTransition` handles imperative page jumps and resets. It announces
movement before changing the transform, waits for all animated axes, flushes
the destination, then announces that movement ended. Page pools use that final
notification to load the destination and release their interaction lock.
Superseded or unmounted transitions cannot announce a stale destination; an
intervening gesture remains responsible for its own motion notifications.

The optional `testID` (default `ink-viewport`) identifies the untransformed,
clipped gesture surface. UI tests should pinch this element rather than a parent
screen that also contains sibling toolbars.

`viewportCallbacks` keeps the functions passed to `runOnJS` stable and outside render closures. Committed callbacks are replaced in a layout effect and cleared on unmount, so native animation references cannot retain closed notebook contents or call an unmounted consumer.

Tap selection and gesture exclusion share the inverse of the centered viewport transform, including zoom and pan offsets.
