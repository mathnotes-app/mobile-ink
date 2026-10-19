import notify
import Foundation

// Opt-in only. Native startup is recorded before tests query the view tree;
// interaction windows bracket physical gestures, with accessibility assertions
// outside them. XCTest snapshot traversal can otherwise block the app itself.
final class MobileInkInteractionAudit {
  private let recorder: MobileInkBenchmarkRecorder
  private let scenario: String
  private let prefix: String
  private var observers: [Int32] = []
  private var phase: String? = "startup"
  private var startupWork: DispatchWorkItem?
  private var initialLoadPresented = false
  private var disposed = false

  init?(recorder: MobileInkBenchmarkRecorder) {
    let environment = ProcessInfo.processInfo.environment
    guard environment["MOBILE_INK_AUDIT"] == "1" else { return nil }
    self.recorder = recorder
    scenario = environment["MOBILE_INK_AUDIT_SCENARIO"] ?? "native-interaction"
    prefix = "com.mathnotes.mobile-ink.audit.\(Bundle.main.bundleIdentifier ?? "unknown")."
    recorder.start(scenario: scenario, requestedBackend: MobileInkRenderBackend.ganesh.rawValue)
    observe("begin") { [weak self] in self?.begin() }
    observe("end") { [weak self] in self?.end() }
    let work = DispatchWorkItem { [weak self] in
      guard let self, !self.disposed, self.phase == "startup" else { return }
      self.finish(completed: true)
      self.acknowledge("startup")
    }
    startupWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
  }

  func didPresentInitialLoad() { initialLoadPresented = true }

  func dispose() {
    guard !disposed else { return }
    disposed = true
    startupWork?.cancel()
    finish(completed: false)
    observers.forEach { notify_cancel($0) }
    observers.removeAll()
  }

  deinit { observers.forEach { notify_cancel($0) } }

  private func observe(_ action: String, handler: @escaping () -> Void) {
    var token: Int32 = 0
    let status = notify_register_dispatch(prefix + action, &token, .main) { _ in handler() }
    if status == 0 { observers.append(token) }
    else { NSLog("[MobileInkAudit] Could not register native audit control: %u", status) }
  }

  private func acknowledge(_ action: String) { notify_post(prefix + action + ".ack") }

  private func begin() {
    guard !disposed else { return }
    startupWork?.cancel()
    if phase != nil { finish(completed: false) }
    phase = "interaction"
    recorder.start(scenario: scenario, requestedBackend: currentBackend)
    acknowledge("begin")
  }

  private var currentBackend = MobileInkRenderBackend.ganesh.rawValue
  func updateRequestedBackend(_ backend: String) { currentBackend = backend }

  private func end() {
    guard !disposed else { return }
    if phase == "interaction" { finish(completed: true) }
    acknowledge("end")
  }

  private func finish(completed: Bool) {
    guard let phase else { return }
    self.phase = nil
    var report = recorder.finish()
    report["phase"] = phase
    report["completed"] = completed
    report["initialLoadPresented"] = initialLoadPresented
    MobileInkBenchmarkRecorder.writeAutomaticAudit(report)
  }
}
