import Foundation
import React

@objc(MobileInkPdfExport)
final class MobileInkPdfExport: NSObject {
  private let queue = DispatchQueue(label: "io.mathnotes.mobileink.pdf-export", qos: .userInitiated)
  private var writers: [String: MobileInkPdfWriter] = [:]

  @objc static func requiresMainQueueSetup() -> Bool { false }

  @objc func begin(_ sourceUri: String?, resolver: @escaping RCTPromiseResolveBlock,
                   rejecter: @escaping RCTPromiseRejectBlock) {
    queue.async {
      do {
        let id = UUID().uuidString
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Notebook-\(id).pdf")
        let writer = try MobileInkPdfWriter(output: url, sourceUri: sourceUri)
        self.writers[id] = writer
        resolver(["id": id, "sourcePageCount": writer.sourcePageCount])
      } catch {
        rejecter("E_NOTEBOOK_PDF_SOURCE", "Could not open the source PDF.", error)
      }
    }
  }

  @objc func append(_ id: String, pages: [[String: Any]], resolver: @escaping RCTPromiseResolveBlock,
                    rejecter: @escaping RCTPromiseRejectBlock) {
    queue.async {
      do {
        guard let writer = self.writers[id] else { throw MobileInkPdfError.closed }
        for page in pages { try autoreleasepool { try writer.append(page) } }
        resolver(true)
      } catch {
        self.writers[id] = nil
        rejecter("E_NOTEBOOK_PDF_PAGE", "Could not export a notebook page.", error)
      }
    }
  }

  @objc func finish(_ id: String, resolver: @escaping RCTPromiseResolveBlock,
                    rejecter: @escaping RCTPromiseRejectBlock) {
    queue.async {
      do {
        guard let writer = self.writers.removeValue(forKey: id) else { throw MobileInkPdfError.closed }
        resolver(try writer.finish().absoluteString)
      } catch {
        rejecter("E_NOTEBOOK_PDF_WRITE", "Could not finish the exported PDF.", error)
      }
    }
  }

  @objc func cancel(_ id: String, resolver: @escaping RCTPromiseResolveBlock, rejecter: @escaping RCTPromiseRejectBlock) {
    queue.async {
      self.writers[id] = nil
      resolver(true)
    }
  }
}
