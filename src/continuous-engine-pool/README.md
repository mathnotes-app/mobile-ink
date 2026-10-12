# Continuous engine pool

The pool keeps three native canvases mounted and reassigns them to nearby pages.
`PooledCanvasSlot` owns loading, previews, native events, and the page-local view.
`helpers` defines assignment keys and retry behavior; `types` defines the host API.

`renderViewport` converts the viewport's center-origin scale and translation into
page-local native rendering ratios. The page stack is horizontally centered;
its x offset is `(containerWidth - pageWidth) / 2`, including when a page is wider
than the viewport. Vertical coordinates include content padding and page index.
Offscreen slots fall back to base resolution. The visible rectangle only controls
rendering quality; it must not truncate stored drawing data.

The viewport unit tests cover centered, narrow, panned, and page-straddling views.
The pool integration test checks the ratios delivered to the native canvas.

Stroke serialization must return a real native payload or reject. The pooled
slot no longer substitutes an empty drawing for a native read failure. It also
rejects a read if the slot's assignment changes before the result arrives, so a
save cannot attribute another page's data to the old page. A successfully read
empty drawing remains valid (including an intentional erase-all). Consumers
must preserve their last good page data and retry/report a failed save; they
must not turn a rejection into an empty drawing.

Assignments run through a serialized, latest-request queue. Superseded waiting
windows are skipped; an in-flight native load finishes before another starts.
Captures update pending assignments so a quick return cannot reload stale ink.
The slot captures dirty data before hiding, moving, or unregistering its current
page. Empty payloads and failed capture commits reject the assignment and retain
the old loaded slot. Preview failures alone do not invalidate a successful save.
All slot operations settle before the pool updates its actual page-to-slot map.
A failed load never emits whole-pool readiness; the caller receives the error
and may retry. Hosts must handle rejected assignments and must not advance their
settled-range checkpoint on failure.
