# Continuous notebook canvas

ContinuousDocumentCanvas exposes recordExternalEdit and onExternalEdit for host
overlays sharing native ink history. External undo/redo bypasses ink capture and
auto-page growth; the host applies its own validated overlay patch and persists it.
