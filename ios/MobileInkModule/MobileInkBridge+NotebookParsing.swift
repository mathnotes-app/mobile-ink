import Foundation
import React

extension MobileInkBridge {
  // Parse the exact payload selected by the caller's recovery logic. Reading
  // a file by ID here could replace a newer cloud/cache candidate with stale ink.
  @objc func parseNotebookData(
    _ data: String,
    resolver: @escaping RCTPromiseResolveBlock,
    rejecter: @escaping RCTPromiseRejectBlock
  ) {
    DispatchQueue.global(qos: .userInitiated).async {
      autoreleasepool {
        do {
          let parsed = try JSONSerialization.jsonObject(with: Data(data.utf8))
          guard let notebook = parsed as? [String: Any] else {
            rejecter("INVALID_NOTEBOOK", "Notebook root must be an object", nil)
            return
          }
          resolver(notebook)
        } catch {
          rejecter("PARSE_FAILED", error.localizedDescription, error)
        }
      }
    }
  }
}
