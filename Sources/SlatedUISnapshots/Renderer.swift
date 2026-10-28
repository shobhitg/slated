import AppKit
import SwiftUI

/// Renders SwiftUI views offscreen with `cacheDisplay`, the way the snapshot tool needs it.
///
/// What it takes to get faithful captures on macOS 26 (`--probe` re-checks each point on the
/// current OS):
/// - The window must be borderless. Under a title bar, even a transparent one, scroll views and
///   lists get macOS 26's scroll edge effect and capture blank.
/// - The Liquid Glass sidebar of a `NavigationSplitView` never captures (nor did it always draw on
///   screen), so the main window doesn't use one: its sidebar is plain views.
/// - The hosting view doesn't size its window (`sizingOptions = []`), so every capture is exactly
///   the requested size.
/// - Captures have transparent areas; they're composited onto the window background with
///   `.sourceOver` (`NSImageRep.draw(in:)` alone would copy, dropping alpha).
enum Renderer {
  struct Options {
    var scale: CGFloat = 2
    var styleMask: NSWindow.StyleMask = [.borderless]
    var hostSizing: NSHostingSizingOptions = []
  }

  /// Renders `view` at `size` (height 0: as tall as the content wants) in light or dark appearance.
  static func render(_ view: AnyView, size: CGSize, dark: Bool, options: Options = Options()) -> NSBitmapImageRep {
    let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
    let host = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light))
    host.appearance = appearance
    var size = size
    if size.height == 0 {
      host.frame = CGRect(x: 0, y: 0, width: size.width, height: 10)
      size.height = ceil(host.fittingSize.height)
    }
    host.frame = CGRect(origin: .zero, size: size)
    host.sizingOptions = options.hostSizing

    let window = NSWindow(contentRect: host.frame, styleMask: options.styleMask, backing: .buffered, defer: false)
    if options.styleMask.contains(.titled) {
      window.titlebarAppearsTransparent = true
      window.titleVisibility = .hidden
    }
    window.appearance = appearance
    window.contentView = host
    window.setFrameOrigin(NSPoint(x: -40000, y: -40000))
    window.orderFrontRegardless()
    // Let SwiftUI lay out, run onAppear work and settle animations.
    for _ in 0..<3 {
      host.layoutSubtreeIfNeeded()
      RunLoop.main.run(until: Date().addingTimeInterval(0.25))
    }
    window.displayIfNeeded()

    let capture = bitmap(size: size, scale: options.scale)
    host.cacheDisplay(in: host.bounds, to: capture)
    let output = bitmap(size: size, scale: options.scale)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: output)
    appearance.performAsCurrentDrawingAppearance {
      NSColor.windowBackgroundColor.setFill()
      NSRect(origin: .zero, size: size).fill()
    }
    capture.draw(
      in: NSRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
      hints: nil)
    NSGraphicsContext.restoreGraphicsState()
    window.orderOut(nil)
    return output
  }

  static func bitmap(size: CGSize, scale: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
      bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    return rep
  }

  /// The share of sampled pixels that differ from the most common color, optionally within `rect`
  /// (points, top-left origin). A capture that failed (only background) scores near 0; real UI
  /// scores well above 0.02.
  static func contentFraction(_ rep: NSBitmapImageRep, in rect: CGRect? = nil) -> Double {
    let scale = CGFloat(rep.pixelsWide) / rep.size.width
    let bounds = CGRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh)
    let region =
      (rect.map { CGRect(x: $0.minX * scale, y: $0.minY * scale, width: $0.width * scale, height: $0.height * scale) }
      ?? bounds).intersection(bounds)
    var counts: [UInt32: Int] = [:]
    var total = 0
    let step = max(2, Int(scale) * 2)
    for y in stride(from: Int(region.minY), to: Int(region.maxY), by: step) {
      for x in stride(from: Int(region.minX), to: Int(region.maxX), by: step) {
        guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
        // Quantize to 5 bits per channel so antialiasing noise doesn't count as content.
        let r = UInt32(color.redComponent * 31)
        let g = UInt32(color.greenComponent * 31)
        let b = UInt32(color.blueComponent * 31)
        counts[r << 10 | g << 5 | b, default: 0] += 1
        total += 1
      }
    }
    guard total > 0, let dominant = counts.values.max() else { return 0 }
    return 1 - Double(dominant) / Double(total)
  }

  static func writePNG(_ rep: NSBitmapImageRep, to url: URL) throws {
    guard let png = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
    try png.write(to: url)
  }
}
