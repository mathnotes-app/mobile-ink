# Changelog

All notable changes to `@mathnotes/mobile-ink` will be documented here.

## [0.3.10] - 2026-10-19

- Decode continuous notebooks once on the iOS background queue and hand prepared geometry to the canvas, avoiding combined-document base64 encoding and main-thread decoding on open.
- Add opt-in native audit reports with independent main-queue heartbeat delays, render timing, and memory counters. Unattended UI tests can set `MOBILE_INK_AUDIT=1`; reports contain no drawing or note content and are written when the canvas releases.
- Support continuous-document overview rendering down to 25% zoom without truncating later pages at the native drawable limit.
- Collect visible stroke candidates once per tile-render batch, preserving complete cached tiles for subsequent pans instead of scanning the entire notebook for each tile.
- Keep iOS document extent and CPU upload buffers synchronized when a document grows or its crop changes without a Metal drawable-size callback.
- Extend native checks for drawing on new pages, overview live input, partially visible tile reuse, and new strokes received while a dense notebook snapshot is encoded.
- Let continuous-document hosts exclude selected overlay bodies and controls from viewport panning while keeping blank margins available for navigation.

## [0.3.9] - 2026-10-13

- Saving no longer blocks pen input. iOS and Android copy the strokes on the drawing thread and serialize, base64-encode, and wrap the copy on a background thread. Previously the whole document was serialized on the UI (iOS main / Android GL) thread on every autosave, delaying strokes drawn during a save on dense notebooks.
- Added `captureDocument` (and `NativeInkCanvasRef.captureDocument`): continuous canvases capture page payloads natively by partitioning the stroke copy off the UI thread. `ContinuousDocumentCanvas` uses it, so autosave no longer serializes the whole document, passes it through JavaScript and decodes it again (about 68% less background save CPU on a dense 100-page notebook, simulator).
- Superseded saves reject with `DocumentChangedDuringCaptureError`; `isDocumentCaptureSuperseded` lets hosts treat them as retries rather than failures.
- Continuous-document pan and zoom no longer re-render native ink every frame. `resolveDocumentRenderTarget` renders an overscanned crop that is reused until the visible area leaves it, holds the render resolution during a gesture, and settles at the nearest crisp resolution. `ContinuousDocumentCanvas` uses it and no longer re-renders its subtree on each viewport update.
- Added `npm run test:native:snapshot-smoke`, run in CI.

## [0.3.8] - 2026-10-12

- Added continuous document drawing across page boundaries, preserving stroke order, eraser targets, undo/redo, and page-local save/export data.
- Added external edit history for host-owned text and image changes so their undo/redo remains chronological with ink.
- Render visible zoom regions at the required scale and release obsolete render surfaces; avoid retaining old notebooks in native gesture callbacks.
- Correct tap coordinates in centered zoomed viewports and confirm native loads before marking pages ready.
- Added native parsing of the exact selected notebook payload so recovery does not reread a stale local file.
- Ordinary multi-page notebooks no longer acquire inferred PDF page numbers during loading.

## [0.3.7] - 2026-10-02

- Added `capturePreviewOnReassign` to `ContinuousEnginePool` (default `true`). Hosts that don't use page previews can set it to `false` to skip the native render and PNG encode that runs for every captured page when the pool shifts. Page data is still captured.

## [0.3.6] - 2026-10-02

- iOS: selection hit-testing, the selection toolbar and `onInkSelectionChange` now share one bounds helper that rejects non-finite geometry; the event sends `null` bounds instead of NaN. The selection toolbar ignores selection bounds that are not finite. Inverted or overflowing bounds previously produced a NaN frame and terminated the app with `CALayerInvalidGeometry` (seen in production after a pooled page was cleared with a live selection, which 0.3.5 also fixes at the source).
- The podspec now reads its version from `package.json`, so the CocoaPods version and source tag always match the published package.

## [0.3.5] - 2026-10-02

- Fixed a crash when deleting a selection after Undo, Redo or Clear. The selection kept stroke indices from before the history change, and deleting it underflowed a `size_t` and aborted the app with an uncaught `std::length_error`.
- Fixed Delete or Move after Undo acting on strokes the user never selected. Undo, Redo, Clear and loading now drop index-based selection, object-eraser and transform state, and cancel an in-flight selection transform before reverting.
- iOS hides the selection toolbar after Undo, Redo and Clear, so it no longer offers actions on strokes that are gone.
- Added unit tests for `normalizePagePayloadForNativeLoad` covering blank, malformed, and valid native-load payloads (#12).
- Added `npm run test:native:selection-smoke` regression coverage, run in CI.


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
