import Foundation
import QuartzCore
import Darwin

// Exercise the real heartbeat while the main queue is intentionally blocked.
// The native interaction audit uses the same recorder without artificial work.
@main
struct RecorderHeartbeatSmoke {
  static func main() {
    let frameRecorder = MobileInkBenchmarkRecorder()
    frameRecorder.start(scenario: "frame-input-association", requestedBackend: "cpu")
    let timestamp = CACurrentMediaTime()
    frameRecorder.recordInputSample(at: timestamp)
    let firstFrame = frameRecorder.prepareFrame()!
    frameRecorder.recordInputSample(at: timestamp + 0.010)
    frameRecorder.recordPresentedFrame(token: firstFrame, backend: .cpu, didFallbackFromGanesh: false,
      renderDurationMs: 1, completedAt: timestamp + 0.005, maximumFramesPerSecond: 60)
    let secondFrame = frameRecorder.prepareFrame()!
    frameRecorder.recordPresentedFrame(token: secondFrame, backend: .cpu, didFallbackFromGanesh: false,
      renderDurationMs: 1, completedAt: timestamp + 0.015, maximumFramesPerSecond: 60)
    let frames = frameRecorder.finish()
    guard let latency = frames["inputToPresentLatencyMs"] as? [String: Any],
          latency["count"] as? Int == 2, latency["p50"] as? Double == 5,
          latency["max"] as? Double == 5 else {
      fputs("Frame completion consumed newer input or produced a negative latency\n", stderr)
      exit(1)
    }
    frameRecorder.start(scenario: "new-frame-session", requestedBackend: "cpu")
    frameRecorder.recordPresentedFrame(token: firstFrame, backend: .cpu, didFallbackFromGanesh: false,
      renderDurationMs: 1, completedAt: timestamp + 0.020, maximumFramesPerSecond: 60)
    guard frameRecorder.finish()["renderFrameCount"] as? Int == 0 else {
      fputs("Old frame completion leaked into a new recording\n", stderr)
      exit(1)
    }
    let recorder = MobileInkBenchmarkRecorder()
    recorder.start(scenario: "heartbeat-smoke", requestedBackend: "cpu")
    recorder.updateRequestedBackend("ganesh")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
      Thread.sleep(forTimeInterval: 0.18)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
      let first = recorder.finish()
      guard let delays = first["mainQueueDelayMs"] as? [String: Any],
            let maximum = delays["max"] as? Double,
            let count = first["mainQueueStallCount"] as? Int,
            maximum >= 100, count >= 1, first["requestedBackend"] as? String == "ganesh" else {
        fputs("Heartbeat failed to detect the intentional main-queue stall\n", stderr)
        exit(1)
      }
      // A new recording must not retain the old stall or its queued callbacks.
      recorder.start(scenario: "heartbeat-restart", requestedBackend: "cpu")
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
        let second = recorder.finish()
        guard let fresh = second["mainQueueDelayMs"] as? [String: Any],
              let samples = fresh["count"] as? Int, samples > 0,
              let scenario = second["scenario"] as? String, scenario == "heartbeat-restart" else {
          fputs("Heartbeat did not restart cleanly\n", stderr)
          exit(1)
        }
        print("Heartbeat detected a \(maximum) ms stall and restarted successfully")
        exit(0)
      }
    }
    dispatchMain()
  }
}
