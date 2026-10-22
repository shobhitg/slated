// Renders Slated's app icon with CoreGraphics and writes Resources/AppIcon.icns.
// Usage: swift scripts/make-icon.swift [output.icns]
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func render(size: Int) -> CGImage {
  let s = CGFloat(size)
  let ctx = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  ctx.scaleBy(x: s / 1024, y: s / 1024)
  let rgb = CGColorSpace(name: CGColorSpace.sRGB)!
  func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(
      colorSpace: rgb,
      components: [CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, a])!
  }

  // macOS icon grid: an 824pt body with ~185pt continuous-looking corners.
  let body = CGRect(x: 100, y: 100, width: 824, height: 824)
  let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

  // Soft drop shadow under the body.
  ctx.saveGState()
  ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
  ctx.addPath(bodyPath)
  ctx.setFillColor(color(0x5B5BF7))
  ctx.fillPath()
  ctx.restoreGState()

  // Indigo → violet → pink gradient.
  ctx.saveGState()
  ctx.addPath(bodyPath)
  ctx.clip()
  let gradient = CGGradient(
    colorsSpace: rgb, colors: [color(0x4F46E5), color(0x8B5CF6), color(0xEC4899)] as CFArray,
    locations: [0, 0.55, 1])!
  ctx.drawLinearGradient(gradient, start: CGPoint(x: 100, y: 924), end: CGPoint(x: 924, y: 100), options: [])
  // Glassy highlight on the top half.
  let shine = CGGradient(colorsSpace: rgb, colors: [color(0xFFFFFF, 0.28), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
  ctx.drawLinearGradient(shine, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 520), options: [])
  ctx.restoreGState()

  // Glyph: a tiled layout — one tall tile on the left, two stacked on the right.
  let inner = CGRect(x: 262, y: 300, width: 500, height: 424)
  let gap: CGFloat = 30
  let leftWidth = (inner.width - gap) * 0.54
  let tiles: [(CGRect, CGFloat)] = [
    (CGRect(x: inner.minX, y: inner.minY, width: leftWidth, height: inner.height), 1.0),
    (CGRect(x: inner.minX + leftWidth + gap, y: inner.midY + gap / 2, width: inner.width - leftWidth - gap, height: inner.height / 2 - gap / 2), 0.78),
    (CGRect(x: inner.minX + leftWidth + gap, y: inner.minY, width: inner.width - leftWidth - gap, height: inner.height / 2 - gap / 2), 0.58),
  ]
  ctx.saveGState()
  ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: color(0x1E1B4B, 0.35))
  for (rect, alpha) in tiles {
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 38, cornerHeight: 38, transform: nil))
    ctx.setFillColor(color(0xFFFFFF, alpha))
    ctx.fillPath()
  }
  ctx.restoreGState()

  // Title-bar dots on the main tile.
  for (i, hex) in [0x4F46E5, 0x8B5CF6, 0xEC4899].enumerated() {
    let dot = CGRect(x: inner.minX + 34 + CGFloat(i) * 40, y: inner.maxY - 58, width: 24, height: 24)
    ctx.setFillColor(color(UInt32(hex), 0.9))
    ctx.fillEllipse(in: dot)
  }
  return ctx.makeImage()!
}

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/AppIcon.icns"
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
  for scale in [1, 2] {
    let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
    let url = iconset.appendingPathComponent(name)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, render(size: base * scale), nil)
    CGImageDestinationFinalize(dest)
  }
}
let png = URL(fileURLWithPath: output).deletingPathExtension().appendingPathExtension("png")
let dest = CGImageDestinationCreateWithURL(png as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, render(size: 512), nil)
CGImageDestinationFinalize(dest)
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", output]
try task.run()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "Wrote \(output) and \(png.path)" : "iconutil failed")
