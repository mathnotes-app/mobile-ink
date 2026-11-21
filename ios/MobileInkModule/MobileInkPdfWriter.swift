import CoreGraphics
import CoreText
import Foundation
import ImageIO

@_silgen_name("mobileInkDrawPdfInk")
private func drawPdfInk(_ data: UnsafePointer<UInt8>, _ length: Int32, _ context: CGContext,
                        _ width: Int32, _ height: Int32, _ density: Float) -> Bool

@_silgen_name("mobileInkDrawPdfPaper")
private func drawPdfPaper(_ background: UnsafePointer<CChar>, _ context: CGContext,
                          _ width: Int32, _ height: Int32, _ pageIndex: Int32)

enum MobileInkPdfError: Error {
  case unreadableSource, invalidPage, invalidLayer, unwritableOutput, closed
}

/// Writes pages incrementally to a file. PDF backgrounds, ordinary ink and text
/// are drawn into the PDF graphics context without an intermediate page bitmap.
final class MobileInkPdfWriter {
  private let output: URL
  private let source: CGPDFDocument?
  private var context: CGContext?
  private var writtenPages = 0
  private var didFinish = false

  var sourcePageCount: Int { source?.numberOfPages ?? 0 }

  init(output: URL, sourceUri: String?) throws {
    self.output = output
    if let sourceUri, !sourceUri.isEmpty {
      let cleanUri = sourceUri.components(separatedBy: "#").first ?? ""
      guard let pdf = Self.pdfDocument(cleanUri), !pdf.isEncrypted || pdf.isUnlocked
      else { throw MobileInkPdfError.unreadableSource }
      source = pdf
    } else {
      source = nil
    }
    var page = CGRect(x: 0, y: 0, width: 612, height: 792)
    guard let context = CGContext(output as CFURL, mediaBox: &page, nil) else {
      throw MobileInkPdfError.unwritableOutput
    }
    self.context = context
  }

  deinit {
    context?.closePDF()
    if !didFinish { try? FileManager.default.removeItem(at: output) }
  }

  func append(_ page: [String: Any]) throws {
    guard let context else { throw MobileInkPdfError.closed }
    let width = number(page["width"], 0)
    let height = number(page["height"], 0)
    let density = number(page["density"], 2)
    guard (1...16384).contains(width), (1...16384).contains(height),
          (1...4).contains(density), let layers = page["layers"] as? [[String: Any]]
    else { throw MobileInkPdfError.invalidPage }

    let canvas = CGRect(x: 0, y: 0, width: width, height: height)
    let sheet = CGRect(x: 0, y: 0, width: 612, height: 792)
    let bound = fit(canvas.size, in: sheet)
    context.beginPDFPage(nil)
    defer { context.endPDFPage() }

    if let pageNumber = page["pdfPage"] as? Int {
      guard pageNumber > 0, let sourcePage = source?.page(at: pageNumber) else {
        throw MobileInkPdfError.invalidPage
      }
      try drawOriginal(sourcePage, in: bound, context)
    }

    // The app positions annotations in a top-left coordinate system.
    context.saveGState()
    defer { context.restoreGState() }
    context.translateBy(x: bound.minX, y: bound.maxY)
    context.scaleBy(x: bound.width / width, y: -bound.height / height)
    context.clip(to: canvas)
    if page["pdfPage"] == nil, let paper = page["paper"] as? String {
      let index = min(Int32.max, Int32(clamping: (page["pageIndex"] as? Int) ?? writtenPages))
      paper.withCString { drawPdfPaper($0, context, Int32(width), Int32(height), index) }
    }
    for layer in layers {
      try autoreleasepool {
        switch layer["kind"] as? String {
        case "ink": try drawInkLayer(layer, in: canvas, density: Float(density), context)
        case "image": try drawImageLayer(layer, context)
        case "text": try drawTextLayer(layer, context)
        case "overlay":
          guard let uri = layer["uri"] as? String else { throw MobileInkPdfError.invalidLayer }
          let image = try decodeImage(uri)
          drawImage(image, in: canvas, context)
        default: throw MobileInkPdfError.invalidLayer
        }
      }
    }
    writtenPages += 1
  }

  func finish() throws -> URL {
    guard let context, writtenPages > 0 else { throw MobileInkPdfError.closed }
    context.closePDF()
    self.context = nil
    didFinish = true
    return output
  }

  private func drawOriginal(_ page: CGPDFPage, in rect: CGRect, _ context: CGContext) throws {
    // Same media-box fit as MobileInkBackgroundView, which is where the ink
    // coordinates were authored. CGPDFPage stays vector in this context.
    let media = page.getBoxRect(.mediaBox)
    guard media.width > 0, media.height > 0 else { throw MobileInkPdfError.invalidPage }
    let dest = fit(media.size, in: rect)
    let scale = dest.width / media.width
    context.saveGState()
    defer { context.restoreGState() }
    context.clip(to: dest)
    context.translateBy(x: dest.minX - media.minX * scale, y: dest.minY - media.minY * scale)
    context.scaleBy(x: scale, y: scale)
    context.drawPDFPage(page)
  }

  private func drawInkLayer(_ layer: [String: Any], in rect: CGRect, density: Float,
                            _ context: CGContext) throws {
    guard let drawing = layer["drawing"] as? String, let json = drawing.data(using: .utf8),
          let root = try JSONSerialization.jsonObject(with: json) as? [String: Any],
          let pages = root["pages"] as? [String: String]
    else { throw MobileInkPdfError.invalidLayer }
    if pages.isEmpty { return }
    guard let base64 = pages["0"], let data = Data(base64Encoded: base64),
          !data.isEmpty, data.count <= Int32.max else { throw MobileInkPdfError.invalidLayer }
    let rendered = data.withUnsafeBytes { bytes -> Bool in
      guard let start = bytes.bindMemory(to: UInt8.self).baseAddress else { return false }
      return drawPdfInk(start, Int32(data.count), context, Int32(rect.width), Int32(rect.height), density)
    }
    if !rendered { throw MobileInkPdfError.invalidLayer }
  }

  private func drawTextLayer(_ layer: [String: Any], _ context: CGContext) throws {
    guard let content = layer["text"] as? String else { throw MobileInkPdfError.invalidLayer }
    if content.isEmpty { return }
    let bounds = try box(layer)
    let padding = max(0, number(layer["padding"], 8))
    let textRect = bounds.insetBy(dx: padding, dy: padding)
    guard !textRect.isEmpty else { return }
    let size = max(1, min(1024, number(layer["fontSize"], 18)))
    let font = CTFontCreateUIFontForLanguage(.user, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
    let color = hexColor(layer["color"] as? String)
    let attributes: [NSAttributedString.Key: Any] = [
      NSAttributedString.Key(kCTFontAttributeName as String): font,
      NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
    ]
    let text = NSAttributedString(string: content, attributes: attributes)
    let framesetter = CTFramesetterCreateWithAttributedString(text)
    let target = CGRect(origin: .zero, size: textRect.size)
    let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0),
      CGPath(rect: target, transform: nil), nil)
    context.saveGState()
    defer { context.restoreGState() }
    context.clip(to: textRect)
    context.translateBy(x: textRect.minX, y: textRect.maxY)
    context.scaleBy(x: 1, y: -1)
    context.textMatrix = .identity
    CTFrameDraw(frame, context)
  }

  private func drawImageLayer(_ layer: [String: Any], _ context: CGContext) throws {
    guard let uri = layer["uri"] as? String else { throw MobileInkPdfError.invalidLayer }
    let bounds = try box(layer)
    let image = try decodeImage(uri)
    let crop = layer["crop"] as? [String: Any] ?? [:]
    let cropX = min(0.999, max(0, number(crop["x"], 0)))
    let cropY = min(0.999, max(0, number(crop["y"], 0)))
    let cropWidth = min(1 - cropX, max(0.001, number(crop["width"], 1)))
    let cropHeight = min(1 - cropY, max(0.001, number(crop["height"], 1)))
    let full = CGSize(width: bounds.width / cropWidth, height: bounds.height / cropHeight)
    let imageSize = CGSize(width: image.width, height: image.height)
    let cover = max(full.width / imageSize.width, full.height / imageSize.height)
    let w = imageSize.width * cover, h = imageSize.height * cover

    context.saveGState()
    defer { context.restoreGState() }
    context.translateBy(x: bounds.midX, y: bounds.midY)
    context.rotate(by: number(layer["rotation"], 0).truncatingRemainder(dividingBy: 360) * .pi / 180)
    context.translateBy(x: -bounds.midX, y: -bounds.midY)
    let radius = max(0, min(min(bounds.width, bounds.height) / 2, number(layer["cornerRadius"], 4)))
    context.addPath(CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil))
    context.clip()
    drawImage(image, in: CGRect(x: bounds.minX - cropX * full.width + (full.width - w) / 2,
                               y: bounds.minY - cropY * full.height + (full.height - h) / 2,
                               width: w, height: h), context)
  }

  private func drawImage(_ image: CGImage, in rect: CGRect, _ context: CGContext) {
    context.saveGState()
    context.translateBy(x: rect.minX, y: rect.maxY)
    context.scaleBy(x: 1, y: -1)
    context.draw(image, in: CGRect(origin: .zero, size: rect.size))
    context.restoreGState()
  }

  private func decodeImage(_ uri: String) throws -> CGImage {
    let source: CGImageSource?
    if uri.hasPrefix("data:image/"), let comma = uri.firstIndex(of: ","),
       uri[..<comma].hasSuffix(";base64"), let data = Data(base64Encoded: String(uri[uri.index(after: comma)...])) {
      source = CGImageSourceCreateWithData(data as CFData, nil)
    } else if let url = Self.fileURL(uri) {
      source = CGImageSourceCreateWithURL(url as CFURL, nil)
    } else {
      source = nil
    }
    guard let source else { throw MobileInkPdfError.invalidLayer }
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    let orientation = properties?[kCGImagePropertyOrientation] as? Int ?? 1
    if orientation != 1,
       let width = properties?[kCGImagePropertyPixelWidth] as? Int,
       let height = properties?[kCGImagePropertyPixelHeight] as? Int,
       let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
         kCGImageSourceCreateThumbnailFromImageAlways: true,
         kCGImageSourceCreateThumbnailWithTransform: true,
         kCGImageSourceThumbnailMaxPixelSize: max(width, height),
       ] as CFDictionary) {
      return image
    }
    guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
      throw MobileInkPdfError.invalidLayer
    }
    return image
  }

  private static func pdfDocument(_ uri: String) -> CGPDFDocument? {
    if let url = fileURL(uri) { return CGPDFDocument(url as CFURL) }
    let prefix = "data:application/pdf;base64,"
    guard uri.hasPrefix(prefix),
          let data = Data(base64Encoded: String(uri.dropFirst(prefix.count)), options: .ignoreUnknownCharacters),
          let provider = CGDataProvider(data: data as CFData) else { return nil }
    return CGPDFDocument(provider)
  }

  private static func fileURL(_ uri: String) -> URL? {
    if uri.hasPrefix("/") { return URL(fileURLWithPath: uri) }
    if let url = URL(string: uri), url.isFileURL { return url }
    return nil
  }

  private func number(_ value: Any?, _ fallback: CGFloat) -> CGFloat {
    guard let number = value as? NSNumber, number.doubleValue.isFinite else { return fallback }
    return CGFloat(number.doubleValue)
  }

  private func box(_ layer: [String: Any]) throws -> CGRect {
    let width = number(layer["width"], 0), height = number(layer["height"], 0)
    guard width > 0, height > 0 else { throw MobileInkPdfError.invalidLayer }
    return CGRect(x: number(layer["x"], 0), y: number(layer["y"], 0), width: width, height: height)
  }

  private func fit(_ size: CGSize, in rect: CGRect) -> CGRect {
    let scale = min(rect.width / size.width, rect.height / size.height)
    let width = size.width * scale, height = size.height * scale
    return CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
  }

  private func hexColor(_ color: String?) -> CGColor {
    let raw = color?.hasPrefix("#") == true ? String(color!.dropFirst()) : ""
    let hex = raw.count == 3 || raw.count == 4 ? raw.map { "\($0)\($0)" }.joined() : raw
    guard (hex.count == 6 || hex.count == 8), let value = UInt32(hex, radix: 16) else {
      return CGColor(gray: 0, alpha: 1)
    }
    let rgb = hex.count == 8 ? value >> 8 : value
    return CGColor(red: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255,
                   blue: CGFloat(rgb & 255) / 255, alpha: hex.count == 8 ? CGFloat(value & 255) / 255 : 1)
  }
}
