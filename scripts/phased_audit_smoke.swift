import Darwin
import Foundation
import notify

@main
struct PhasedAuditSmoke {
  static func main() {
    let scenario = "phase-smoke-" + UUID().uuidString
    setenv("MOBILE_INK_AUDIT", "1", 1)
    setenv("MOBILE_INK_AUDIT_SCENARIO", scenario, 1)
    let recorder = MobileInkBenchmarkRecorder()
    guard let audit = MobileInkInteractionAudit(recorder: recorder) else { exit(1) }
    audit.didPresentInitialLoad()
    let prefix = "com.mathnotes.mobile-ink.audit.\(Bundle.main.bundleIdentifier ?? "unknown")."
    var tokens: [Int32] = []
    var frozenMaximum: Double?
    func fail(_ message: String) -> Never { fputs(message + "\n", stderr); exit(1) }
    func observe(_ action: String, _ body: @escaping () -> Void) {
      var token: Int32 = 0
      guard notify_register_dispatch(prefix + action + ".ack", &token, .main, { _ in body() }) == 0 else {
        fail("Could not observe audit control")
      }
      tokens.append(token)
    }
    let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("MobileInkAudits")
    func verify(_ attempt: Int = 0) {
      do {
        let reports = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
          .filter { $0.pathExtension == "json" }.compactMap { file -> (URL, [String: Any])? in
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
            return object?["scenario"] as? String == scenario ? (file, object!) : nil
          }
        if reports.count < 2 && attempt < 30 {
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { verify(attempt + 1) }
          return
        }
        guard reports.count == 2,
              let startup = reports.first(where: { $0.1["phase"] as? String == "startup" })?.1,
              let interaction = reports.first(where: { $0.1["phase"] as? String == "interaction" })?.1,
              startup["initialLoadPresented"] as? Bool == true, startup["completed"] as? Bool == true,
              interaction["completed"] as? Bool == true,
              let delays = interaction["mainQueueDelayMs"] as? [String: Any],
              let maximum = delays["max"] as? Double, maximum >= 100,
              maximum == frozenMaximum else { fail("Startup/window evidence was incomplete or changed after stop") }
        for report in reports { try FileManager.default.removeItem(at: report.0) }
        audit.dispose()
        tokens.forEach { notify_cancel($0) }
        print("Startup and acknowledged gesture windows passed; later main-thread work was excluded")
        exit(0)
      } catch { fail("Cannot verify audit output: \(error)") }
    }
    observe("startup") { notify_post(prefix + "begin") }
    observe("begin") {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { Thread.sleep(forTimeInterval: 0.14) }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { notify_post(prefix + "end") }
    }
    observe("end") {
      frozenMaximum = (recorder.summary()["mainQueueDelayMs"] as? [String: Any])?["max"] as? Double
      Thread.sleep(forTimeInterval: 0.18)
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { verify() }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 10) { fail("Audit control timed out") }
    dispatchMain()
  }
}
