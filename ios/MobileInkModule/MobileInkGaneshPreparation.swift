import Foundation
import Metal

enum MobileInkGaneshPreparation {
  final class Request {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool {
      lock.lock()
      defer { lock.unlock() }
      return cancelled
    }
  }
  // Bound shader/compiler work when several canvas views mount together.
  private static let queue = DispatchQueue(label: "com.mathnotes.ink.ganesh-preparation", qos: .userInitiated)

  static func prepare(device: MTLDevice, commandQueue: MTLCommandQueue,
                      completion: @escaping (OpaquePointer?) -> Void) -> Request {
    let request = Request()
    queue.async {
      guard !request.isCancelled else { return }
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
      if request.isCancelled {
        if let preparedContext { destroyGaneshMetalContext(preparedContext) }
        return
      }
      DispatchQueue.main.async {
        if request.isCancelled {
          if let preparedContext { discard(preparedContext) }
          return
        }
        completion(preparedContext)
      }
    }
    return request
  }

  static func discard(_ context: OpaquePointer) {
    queue.async { destroyGaneshMetalContext(context) }
  }
}
