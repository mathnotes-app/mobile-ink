import CoreGraphics
import CoreText
import Foundation

@_silgen_name("writePdfExportInkFixture")
private func writeInkFixture(_ destination: UnsafePointer<CChar>, _ textured: Bool) -> Bool

@main
struct PdfExportSmoke {
  static func main() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let original = root.appendingPathComponent("source.pdf")
    var media = CGRect(x: 0, y: 0, width: 612, height: 792)
    let context = CGContext(original as CFURL, mediaBox: &media, nil)!
    let label = NSAttributedString(string: "Electrical plan A-102", attributes: [
      NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 6, nil),
    ])
    context.beginPDFPage(nil)
    context.textPosition = CGPoint(x: 70, y: 700)
    CTLineDraw(CTLineCreateWithAttributedString(label), context)
    context.endPDFPage()
    context.closePDF()

    func ink(textured: Bool) throws -> [String: Any] {
      let url = root.appendingPathComponent(textured ? "crayon.bin" : "pen.bin")
      precondition(url.path.withCString { writeInkFixture($0, textured) })
      let data = try Data(contentsOf: url).base64EncodedString()
      return ["kind": "ink", "drawing": "{\"pages\":{\"0\":\"\(data)\"}}"]
    }
    let text: [String: Any] = ["kind": "text", "text": "Check circuit 4", "color": "#242424",
                                "fontSize": 14, "x": 70, "y": 280, "width": 400, "height": 55]
    let writer = try MobileInkPdfWriter(output: root.appendingPathComponent("export.pdf"), sourceUri: original.absoluteString)
    try writer.append(["width": 612, "height": 792, "density": 2, "pdfPage": 1, "layers": [try ink(textured: false), text]])
    try writer.append(["width": 612, "height": 792, "density": 2, "paper": "dotted", "layers": [try ink(textured: true)]])
    let output = try writer.finish()
    let pdf = CGPDFDocument(output as CFURL)!
    precondition(pdf.numberOfPages == 2)
    let page = pdf.page(at: 1)!
    let rendered = CGContext(data: nil, width: 612, height: 792, bitsPerComponent: 8, bytesPerRow: 4 * 612,
                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    rendered.setFillColor(gray: 1, alpha: 1)
    rendered.fill(media)
    rendered.drawPDFPage(page)
    let pixels = rendered.data!.assumingMemoryBound(to: UInt8.self)
    precondition(pixels[(218 * 612 + 115) * 4] < 40, "pen ink is missing or misplaced")
    precondition(pixels[(218 * 612 + 260) * 4] > 245, "pixel eraser hole is missing")

    func poppler(_ program: String, _ arguments: [String]) throws -> String {
      let command = Process()
      command.executableURL = URL(fileURLWithPath: "/usr/bin/env")
      command.arguments = [program] + arguments
      let pipe = Pipe()
      command.standardOutput = pipe
      try command.run()
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      command.waitUntilExit()
      precondition(command.terminationStatus == 0)
      return String(decoding: data, as: UTF8.self)
    }
    let extracted = try poppler("pdftotext", ["-f", "1", "-l", "1", output.path, "-"])
    precondition(extracted.contains("Electrical plan A-102") && extracted.contains("Check circuit 4"))
    let images = try poppler("pdfimages", ["-list", output.path])
    let imagePages = images.split(separator: "\n").dropFirst(2).compactMap { $0.split(separator: " ").first }
    precondition(!imagePages.isEmpty && imagePages.allSatisfy { $0 == "2" },
                 "only the intrinsic crayon texture should be a bitmap: \(images)")
    print("PDF preserves original and added text, pen geometry and erased areas; crayon texture stays isolated")
  }
}
