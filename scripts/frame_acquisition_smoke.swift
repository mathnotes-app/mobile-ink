import Foundation

@main
struct FrameAcquisitionSmoke {
  static func main() {
    let frame = MobileInkFrameAcquisition<Int>()
    let waiting = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    var delivered = false
    var responsive = false
    let started = Date()
    precondition(frame.acquire({
      precondition(!Thread.isMainThread)
      waiting.signal()
      precondition(release.wait(timeout: .now() + 2) == .success)
      return 42
    }, completion: { value in
      precondition(Thread.isMainThread && value == 42)
      delivered = true
    }))
    precondition(waiting.wait(timeout: .now() + 2) == .success)
    precondition(!frame.acquire({ 99 }, completion: { _ in fatalError("Duplicate frame") }))
    DispatchQueue.main.async { responsive = true }
    spin(until: { responsive })
    precondition(Date().timeIntervalSince(started) < 0.5 && !delivered,
                 "Waiting for a drawable blocked the input queue")
    release.signal()
    spin(until: { delivered })
    precondition(!frame.acquire({ 99 }, completion: { _ in fatalError("Encoding still owns the acquisition") }))
    frame.finish()

    var emptyDelivered = false
    precondition(frame.acquire({ nil }, completion: { value in
      precondition(value == nil)
      emptyDelivered = true
      frame.finish()
    }))
    spin(until: { emptyDelivered })

    let blocked = DispatchSemaphore(value: 0)
    let unblock = DispatchSemaphore(value: 0)
    precondition(frame.acquire({
      blocked.signal()
      precondition(unblock.wait(timeout: .now() + 2) == .success)
      return 7
    }, completion: { _ in fatalError("Cancelled canvas received a drawable") }))
    precondition(blocked.wait(timeout: .now() + 2) == .success)
    frame.cancel()
    var replacementDelivered = false
    precondition(frame.acquire({ 8 }, completion: { value in
      precondition(value == 8)
      replacementDelivered = true
      frame.finish()
    }))
    unblock.signal()
    spin(until: { replacementDelivered })
    print("Drawable waits leave main responsive; one acquisition stays in flight; nil and cancelled acquisitions recover")
  }

  private static func spin(until condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(3)
    while !condition(), Date() < deadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.005))
    }
    precondition(condition(), "Frame callback timed out")
  }
}
