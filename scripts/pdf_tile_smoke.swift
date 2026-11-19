import Foundation
import UIKit

@main struct PdfTileSmoke {
  static func main() throws {
    let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("opennotes-vector-detail-\(UUID().uuidString).pdf")
    let page = CGRect(x: 0, y: 0, width: 200, height: 200)
    let data = UIGraphicsPDFRenderer(bounds: page).pdfData { renderer in
      renderer.beginPage()
      let ctx = renderer.cgContext
      ctx.setFillColor(UIColor.white.cgColor); ctx.fill(page)
      ctx.setStrokeColor(UIColor.black.cgColor); ctx.setLineWidth(0.25)
      for i in 0..<100 { let x = CGFloat(i) * 2; ctx.move(to: CGPoint(x:x,y:0)); ctx.addLine(to: CGPoint(x:x,y:200)) }
      ctx.strokePath()
    }
    try data.write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    let view = MobileInkBackgroundView(frame: page)
    view.layoutIfNeeded(); view.backgroundType = "pdf"
    var loaded = false
    view.onLoadingStateChanged = { loading, _ in if !loading { loaded = true } }
    view.loadPDFBackground(uri: file.absoluteString + "#page=1")
    let deadline = Date().addingTimeInterval(10)
    while !loaded && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    guard loaded, let tiles = view.subviews.first else { throw NSError(domain:"pdf-tile-smoke",code:1) }
    let format = UIGraphicsImageRendererFormat(); format.scale = 1
    func render(scale: CGFloat) -> [UInt8] {
      let image = UIGraphicsImageRenderer(size: CGSize(width:200,height:200),format:format).image { r in
        r.cgContext.scaleBy(x: scale, y: scale)
        tiles.draw(CGRect(x:0,y:0,width:200 / scale,height:200 / scale))
      }
      let cg = image.cgImage!
      var pixels = [UInt8](repeating:255,count:200*200*4)
      pixels.withUnsafeMutableBytes { bytes in
        let ctx = CGContext(data: bytes.baseAddress, width: 200, height: 200, bitsPerComponent: 8, bytesPerRow: 800,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: page)
      }
      return stride(from: 0, to: pixels.count, by: 4).map { pixels[$0] }
    }
    let normal = render(scale: 1), zoomed = render(scale: 4)
    let normalDark = normal.filter { $0 < 160 }.count
    let zoomDark = zoomed.filter { $0 < 160 }.count
    print("Normal PDF detail pixels: \(normalDark); zoomed detail pixels: \(zoomDark)")
    if zoomDark <= normalDark + 3000 { throw NSError(domain:"pdf-tile-smoke",code:3) }
  }
}
