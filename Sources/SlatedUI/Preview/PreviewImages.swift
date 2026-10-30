import CoreGraphics
import Foundation
import ImageIO
import SlatedCore
import UniformTypeIdentifiers

/// Sample clipboard images for previews, snapshots and tests: drawn (not shipped as files) into a
/// temporary folder the first time they're asked for, at half their listed pixel size.
enum PreviewImages {
  /// A screenshot of a window on a colorful desktop, saved as a file (so it has a name).
  static let screenshot = ClipboardImage(
    file: "preview-screenshot.png", width: 1440, height: 900, bytes: 412_000,
    name: "Screenshot 2026-10-29 at 09.41.12.png")
  /// A portrait photo: a sunset over hills.
  static let photo = ClipboardImage(file: "preview-photo.png", width: 800, height: 1000, bytes: 268_000)

  private static let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("SlatedPreviewImages", isDirectory: true)

  static func url(for image: ClipboardImage) -> URL? {
    let url = directory.appendingPathComponent(image.file)
    if FileManager.default.fileExists(atPath: url.path) { return url }
    guard image.file == screenshot.file || image.file == photo.file else { return nil }
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return write(image, to: url) ? url : nil
  }

  private static func write(_ image: ClipboardImage, to url: URL) -> Bool {
    let width = image.width / 2
    let height = image.height / 2
    guard
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return false }
    let size = CGSize(width: width, height: height)
    if image.file == screenshot.file {
      drawScreenshot(in: context, size: size)
    } else {
      drawPhoto(in: context, size: size)
    }
    // Written to a temporary name and moved, so a parallel run never reads half a file.
    let partial = url.appendingPathExtension("partial-\(UUID().uuidString)")
    guard let cgImage = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(partial as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { return false }
    CGImageDestinationAddImage(destination, cgImage, nil)
    guard CGImageDestinationFinalize(destination) else { return false }
    if (try? FileManager.default.moveItem(at: partial, to: url)) == nil {
      try? FileManager.default.removeItem(at: partial)
    }
    return FileManager.default.fileExists(atPath: url.path)
  }

  // Core Graphics puts y = 0 at the bottom.

  private static func drawScreenshot(in c: CGContext, size: CGSize) {
    fill(c, CGRect(origin: .zero, size: size), top: (0.42, 0.37, 0.99), bottom: (0.16, 0.62, 0.95))
    let window = CGRect(
      x: size.width * 0.12, y: size.height * 0.1, width: size.width * 0.76, height: size.height * 0.78)
    c.setFillColor(red: 0, green: 0, blue: 0, alpha: 0.18)
    c.addPath(CGPath(roundedRect: window.offsetBy(dx: 0, dy: -6), cornerWidth: 14, cornerHeight: 14, transform: nil))
    c.fillPath()
    c.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
    c.addPath(CGPath(roundedRect: window, cornerWidth: 14, cornerHeight: 14, transform: nil))
    c.fillPath()
    c.setFillColor(red: 0.94, green: 0.94, blue: 0.96, alpha: 1)
    c.fill(CGRect(x: window.minX, y: window.maxY - 44, width: window.width, height: 30))
    c.addPath(
      CGPath(
        roundedRect: CGRect(x: window.minX, y: window.maxY - 44, width: window.width, height: 44), cornerWidth: 14,
        cornerHeight: 14, transform: nil))
    c.fillPath()
    for (index, color) in [(1.0, 0.37, 0.34), (1.0, 0.74, 0.18), (0.16, 0.79, 0.25)].enumerated() {
      c.setFillColor(red: color.0, green: color.1, blue: color.2, alpha: 1)
      c.fillEllipse(in: CGRect(x: window.minX + 18 + CGFloat(index) * 22, y: window.maxY - 29, width: 13, height: 13))
    }
    c.setFillColor(red: 0.42, green: 0.37, blue: 0.99, alpha: 0.9)
    c.fill(CGRect(x: window.minX + 32, y: window.maxY - 96, width: window.width * 0.42, height: 20))
    for line in 0..<7 {
      let width = window.width * (line % 3 == 2 ? 0.48 : 0.8)
      c.setFillColor(red: 0.8, green: 0.8, blue: 0.84, alpha: 1)
      c.fill(CGRect(x: window.minX + 32, y: window.maxY - 136 - CGFloat(line) * 26, width: width, height: 10))
    }
  }

  private static func drawPhoto(in c: CGContext, size: CGSize) {
    fill(c, CGRect(origin: .zero, size: size), top: (0.98, 0.55, 0.36), bottom: (0.99, 0.84, 0.52))
    c.setFillColor(red: 1, green: 0.96, blue: 0.82, alpha: 1)
    c.fillEllipse(
      in: CGRect(x: size.width * 0.32, y: size.height * 0.36, width: size.width * 0.36, height: size.width * 0.36))
    for (index, shade) in [0.42, 0.3, 0.2].enumerated() {
      let base = size.height * (0.42 - CGFloat(index) * 0.12)
      c.setFillColor(red: shade * 0.8, green: shade * 0.55, blue: shade, alpha: 1)
      c.move(to: CGPoint(x: 0, y: 0))
      c.addLine(to: CGPoint(x: 0, y: base))
      c.addCurve(
        to: CGPoint(x: size.width, y: base + size.height * 0.04),
        control1: CGPoint(x: size.width * (0.3 + CGFloat(index) * 0.1), y: base + size.height * 0.16),
        control2: CGPoint(x: size.width * 0.6, y: base - size.height * 0.1))
      c.addLine(to: CGPoint(x: size.width, y: 0))
      c.closePath()
      c.fillPath()
    }
  }

  private static func fill(
    _ c: CGContext, _ rect: CGRect, top: (CGFloat, CGFloat, CGFloat), bottom: (CGFloat, CGFloat, CGFloat)
  ) {
    let colors = [
      CGColor(srgbRed: bottom.0, green: bottom.1, blue: bottom.2, alpha: 1),
      CGColor(srgbRed: top.0, green: top.1, blue: top.2, alpha: 1),
    ]
    guard let gradient = CGGradient(colorsSpace: nil, colors: colors as CFArray, locations: [0, 1]) else { return }
    c.drawLinearGradient(gradient, start: CGPoint(x: 0, y: rect.minY), end: CGPoint(x: 0, y: rect.maxY), options: [])
  }
}
