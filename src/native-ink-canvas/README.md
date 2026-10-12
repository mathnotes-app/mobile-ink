# Native ink bridge

NativeInkCanvas wraps platform drawing views and notebook serialization bridges.
`recordExternalEdit(before, after)` places opaque host-owned overlay patches in
the same bounded native history as strokes. It resolves false if the engine is
unavailable, the edit is unchanged, or a stroke is unfinished; callers must
retain/restore their prior state on rejection. An undo/redo external edit emits
`onDrawingChange.nativeEvent.externalEdit.payload` with the appropriate patch.
Hosts apply only their own overlay schema, without replacing native ink.

External patches are session history, never included in ink serialization. They
follow the same capacity, redo branching and load-reset behavior as ink edits.
Native recording does not emit a drawing change (the host already owns the edit).

Undo/redo events also carry `historyAction: "undo" | "redo"`, including when the
history stack is empty. Hosts can wait for this event to serialize subsequent
asset edits and saves. ContinuousDocumentCanvas forwards it as `onHistoryAction`
after its ink-change or external-overlay callback has run.

`NativeInkCanvasRef.loadDocument` composes page-owned ink and loads the native
canvas without returning a combined drawing through JavaScript. Both platforms
use the existing confirmed canvas-load result. Malformed composition rejects
before canvas mutation; detached views fail instead of claiming hydration.

`parseNotebookData` parses the exact selected JSON payload on a native worker. Unlike `readBodyFileParsed`, it does not read disk or change which recovery candidate is loaded. It returns null only when unavailable; parse failures reject so callers can report or use their validated fallback.
