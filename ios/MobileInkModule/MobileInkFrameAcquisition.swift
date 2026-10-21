import Foundation

// Keep one frame in flight, including the potentially blocking drawable wait.
// Resource acquisition runs away from UIKit; delivery and rendering stay on main.
final class MobileInkFrameAcquisition<Resource> {
  private let queue = DispatchQueue(label: "com.mathnotes.ink.drawable", qos: .userInteractive)
  private let lock = NSLock()
  private var generation: UInt64 = 0
  private var pending = false

  @discardableResult
  func acquire(_ provider: @escaping () -> Resource?, completion: @escaping (Resource?) -> Void) -> Bool {
    lock.lock()
    guard !pending else { lock.unlock(); return false }
    pending = true
    let token = generation
    lock.unlock()
    queue.async {
      let resource = autoreleasepool(invoking: provider)
      DispatchQueue.main.async {
        self.lock.lock()
        let valid = self.generation == token
        self.lock.unlock()
        if valid { completion(resource) }
      }
    }
    return true
  }

  // Called after GPU completion, or when a drawable cannot be submitted.
  func finish() {
    lock.lock()
    pending = false
    lock.unlock()
  }

  func cancel() {
    lock.lock()
    generation &+= 1
    pending = false
    lock.unlock()
  }
}
