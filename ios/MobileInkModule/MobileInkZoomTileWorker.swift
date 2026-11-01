import Foundation
import Metal

// This context and every operation on it remain on the same serial queue.
enum MobileInkZoomTileWorker {
  private static let queue = DispatchQueue(label: "com.mathnotes.ink.zoom-tiles", qos: .userInitiated)
  private static var context: OpaquePointer?

  static func render(_ snapshot: UnsafeMutableRawPointer, completion: @escaping (Int32) -> Void) {
    queue.async {
      if context == nil, let device = MTLCreateSystemDefaultDevice(), let commandQueue = device.makeCommandQueue() {
        context = createGaneshMetalContext(Unmanaged.passUnretained(device).toOpaque(),
                                           Unmanaged.passUnretained(commandQueue).toOpaque())
        if let context { limitZoomTileContext(context) }
      }
      let result = context.map { prepareNextZoomTile(snapshot, $0) } ?? -1
      DispatchQueue.main.async { completion(result) }
    }
  }

  static func clear() {
    queue.async {
      if let current = context { destroyGaneshMetalContext(current) }
      context = nil
    }
  }
}
