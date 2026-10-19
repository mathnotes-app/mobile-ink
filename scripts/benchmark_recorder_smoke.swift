import Foundation
import Darwin

// Exercise the real heartbeat while the main queue is intentionally blocked.
// The native interaction audit uses the same recorder without artificial work.
@main
struct RecorderHeartbeatSmoke {
  static func main() {
    let recorder = MobileInkBenchmarkRecorder()
    recorder.start(scenario: "heartbeat-smoke", requestedBackend: "cpu")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
      Thread.sleep(forTimeInterval: 0.18)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
      let first = recorder.finish()
      guard let delays = first["mainQueueDelayMs"] as? [String: Any],
            let maximum = delays["max"] as? Double,
            let count = first["mainQueueStallCount"] as? Int,
            maximum >= 100, count >= 1 else {
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
