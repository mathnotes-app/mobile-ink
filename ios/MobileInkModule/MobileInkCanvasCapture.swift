import Foundation
import React

extension MobileInkCanvasView {
    /// Copies committed strokes (main thread). The caller owns the result and
    /// must release it with freeDrawingSnapshot after encoding it elsewhere.
    func takeDrawingSnapshot() -> OpaquePointer? {
        guard let engine = drawingEngine else { return nil }
        return snapshotDrawing(engine)
    }

    @objc func getBase64Data(_ callback: @escaping RCTResponseSenderBlock) {
        guard let snapshot = takeDrawingSnapshot() else {
            callback(["Unable to snapshot drawing", NSNull()])
            return
        }
        // Do not capture self or access the live engine on this queue. A view
        // can close, receive new strokes, or undo while this snapshot encodes.
        DispatchQueue.global(qos: .userInitiated).async {
            defer { freeDrawingSnapshot(snapshot) }
            var size: Int32 = 0
            let bytes = serializeDrawingSnapshot(snapshot, &size)
            guard size >= 0 else {
                DispatchQueue.main.async { callback(["Unable to serialize drawing snapshot", NSNull()]) }
                return
            }
            guard let bytes, size > 0 else {
                DispatchQueue.main.async { callback([NSNull(), "{\"pages\":{}}"]) }
                return
            }
            // Base64 text needs no JSON escaping, so the fixed wrapper is built directly.
            let data = Data(bytesNoCopy: bytes, count: Int(size), deallocator: .custom { pointer, _ in
                freeSerializedData(pointer.assumingMemoryBound(to: UInt8.self))
            })
            let payload = "{\"pages\":{\"0\":\"\(data.base64EncodedString())\"}}"
            DispatchQueue.main.async { callback([NSNull(), payload]) }
        }
    }
}
