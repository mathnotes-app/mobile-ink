# Changelog

All notable changes to `@mathnotes/mobile-ink` will be documented here.

## [0.3.4] - 2026-08-15

- Added the optional `overlay` prop to `InfiniteInkCanvas`. Host applications
  can render React overlays inside the UI-thread transformed viewport, keeping
  inserted images, text boxes, and other page content synchronized with ink
  during panning and zooming.

## [0.3.3] - 2026-08-14

- Prevented software-keyboard viewport resizes from being treated as orientation changes.
- Added canvas APIs for revealing a page position and adding a page without automatically scrolling, enabling keyboard-safe text editing in host apps.
- Corrected viewport reveal behavior and trailing-page retention.

## [0.3.2] - 2026-07-15

- Smoothed zoomed drawing and erasing: highlighter and marker render as a single constant-width stroked centerline (no more segment seams at high zoom), the pixel eraser defers stroke bookkeeping to pen-up, and the zoomed stroke preview anchors a constant-memory surface to the viewport instead of allocating canvas-times-zoom pixels.
- Exposed `transformNotificationMinIntervalMs` on `InfiniteInkCanvas` so apps can tune how often JS receives viewport transform notifications (default 16ms).
- Documented continuous canvas positioning.
- Fixed the podspec source tag to match the repository's v-prefixed release tags.

## [0.3.1] - 2026-05-20

- Added crisp settled zoom rendering with scale-aware native drawables and cached stroke tiles.
- Stabilized zoom viewport math so drawing coordinates stay aligned through fast zoom and pan cycles.
- Capped high-zoom native drawable scale to keep Apple Pencil drawing responsive at deep zoom levels.
- Improved large PDF notebook behavior, page background windowing, and selection gesture exclusion regions.
- Fixed an iOS drawable resize recursion that could crash dev builds on launch.

## [0.3.0] - 2026-05-15

- Added the Android native ink renderer with Skia Ganesh GPU rendering and React Native view integration.
- Brought continuous multi-page notebooks to Android, including pooled native canvas activation, page preview overlays while engines mount, and saved notebook reload in the example app.
- Added Android PDF background loading, notebook serialization support, and native smoke coverage.
- Documented Android setup and parity status for the example app and package consumers.

## [0.2.0] - 2026-05-12

- Defaulted the iOS renderer to the Ganesh/Metal path while keeping CPU selectable for A/B comparison and fallback.
- Added on-device benchmark tooling for replayed strokes, manual notebook recordings, scroll sampling, multi-page suites, eraser, selection, and tool coverage.
- Matched Ganesh output colors to the CPU path for highlighter, selection chrome, and other tool colors.

## [0.1.0] - 2026-05-07

Initial public release.

- Added `NativeInkCanvas`, the low-level native Skia/Metal drawing surface for React Native.
- Added `ZoomableInkViewport` for pinch zoom, focal-point zoom, momentum scroll, and Pencil/finger gesture routing.
- Added `ContinuousEnginePool` for fixed-pool native canvas reuse in continuous notebooks.
- Added `InfiniteInkCanvas`, a reusable continuous notebook shell with page growth, serialization, and local save/reload support.
- Added native iOS bridge helpers for page export, notebook parsing, and continuous-window compose/decompose.
- Added an Expo dev-client example app for trying the engine outside MathNotes.
