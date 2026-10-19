import Foundation
import Metal

enum MobileInkGaneshPreparation {
  // Bound shader/compiler work when several canvas views mount together.
  private static let queue = DispatchQueue(label: "com.mathnotes.ink.ganesh-preparation", qos: .userInitiated)

  static func prepare(device: MTLDevice, commandQueue: MTLCommandQueue,
                      completion: @escaping (OpaquePointer?) -> Void) {
    queue.async {
      let preparedContext = withExtendedLifetime((device, commandQueue)) { () -> OpaquePointer? in
        let devicePointer = Unmanaged.passUnretained(device).toOpaque()
        let queuePointer = Unmanaged.passUnretained(commandQueue).toOpaque()
        let context = createGaneshMetalContext(devicePointer, queuePointer)
        if let context, !warmGaneshMetalContext(context, devicePointer) {
          destroyGaneshMetalContext(context)
          return nil
        }
        return context
      }
      // Preparation and GPU submission have finished before ownership moves.
      // The context is never accessed concurrently by these two queues.
      DispatchQueue.main.async { completion(preparedContext) }
    }
  }

  static func discard(_ context: OpaquePointer) {
    queue.async { destroyGaneshMetalContext(context) }
  }
}
