import Foundation
import Metal

// This context and every operation on it remain on the same serial queue.
enum MobileInkZoomTileWorker {
  private static let queue = DispatchQueue(label: "com.mathnotes.ink.zoom-tiles", qos: .utility)
  private static var context: OpaquePointer?
  private static var device: MTLDevice?

  static func render(_ snapshot: UnsafeMutableRawPointer, completion: @escaping (Int32, UnsafeMutableRawPointer?) -> Void) {
    queue.async {
      if context == nil, let device = MTLCreateSystemDefaultDevice(), let commandQueue = device.makeCommandQueue() {
        context = createGaneshMetalContext(Unmanaged.passUnretained(device).toOpaque(),
                                           Unmanaged.passUnretained(commandQueue).toOpaque())
        self.device = device
        if let context { limitZoomTileContext(context) }
      }
      var texture: UnsafeMutableRawPointer?
      let result: Int32
      if let context, let device {
        result = prepareNextZoomTile(snapshot, context, Unmanaged.passUnretained(device).toOpaque(), &texture)
      } else {
        result = -1
      }
      let resultTexture = texture
      DispatchQueue.main.async { completion(result, resultTexture) }
    }
  }

  static func clear() {
    queue.async {
      if let current = context { destroyGaneshMetalContext(current) }
      context = nil
      device = nil
    }
  }
}
