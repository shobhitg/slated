import AppKit

/// Slated's menu bar icon: the app icon's tiles (one tall, two stacked) in one color, as a template
/// image macOS tints to match the menu bar. The same drawing as GNOME's top-bar icons
/// (linux/gnome-extension/icons/slated-*-symbolic.svg, a 16 × 16 grid), plus the Mac's modal variant.
public enum StatusGlyph: String, CaseIterable, Sendable {
  case normal
  /// "Pause Slated": a frame with pause bars.
  case paused
  /// A modal key is waiting for its next key: the tiles as outlines (Slate showed modal mode in the
  /// menu bar too).
  case modal
  /// Something needs attention (the menu says what): an exclamation mark for the lower right tile.
  case warning

  /// Paused before modal before a warning, as on GNOME (which has no modal variant).
  public static func variant(paused: Bool, modal: Bool, warnings: [String]) -> StatusGlyph {
    if paused { return .paused }
    if modal { return .modal }
    return warnings.isEmpty ? .normal : .warning
  }

  /// What needs attention, one line each, for the icon and its menu (GNOME's `statusWarnings`, plus the
  /// Mac's conflicts with other apps).
  public static func warnings(loadError: String?, hotkeys: [String: HotkeyStatus], conflicts: [String]) -> [String] {
    var result: [String] = []
    if let loadError, let first = loadError.split(separator: "\n").first {
      result.append(first.count > 90 ? String(first.prefix(89)) + "…" : String(first))
    }
    let failed = hotkeys.values.filter {
      if case .failed = $0 { return true }
      return false
    }.count
    if failed > 0 {
      result.append(
        "\(failed == 1 ? "1 shortcut" : "\(failed) shortcuts") couldn't be registered: macOS or another app uses the keys"
      )
    }
    return result + conflicts
  }

  /// The icon, 16 × 16 pt, drawn at whatever resolution the menu bar needs.
  public func image() -> NSImage {
    let variant = self
    let image = NSImage(size: NSSize(width: 16, height: 16), flipped: true) { _ in
      variant.draw()
      return true
    }
    image.isTemplate = true
    image.accessibilityDescription = variant == .paused ? "Slated (paused)" : "Slated"
    return image
  }

  /// Draws in a flipped 16 × 16 space, so the numbers read as the SVGs' do.
  private func draw() {
    func tile(_ rect: NSRect, radius: CGFloat, alpha: CGFloat) {
      NSColor.black.withAlphaComponent(alpha).setFill()
      NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    }
    let tall = NSRect(x: 1, y: 2, width: 7, height: 12)
    let upper = NSRect(x: 9.5, y: 2, width: 5.5, height: 5.25)
    let lower = NSRect(x: 9.5, y: 8.75, width: 5.5, height: 5.25)
    switch self {
    case .normal:
      tile(tall, radius: 1.5, alpha: 1)
      tile(upper, radius: 1.25, alpha: 0.8)
      tile(lower, radius: 1.25, alpha: 0.6)
    case .modal:
      NSColor.black.setStroke()
      for (rect, radius) in [(tall, 1.5), (upper, 1.25), (lower, 1.25)] as [(NSRect, CGFloat)] {
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.6, dy: 0.6), xRadius: radius, yRadius: radius)
        path.lineWidth = 1.2
        path.stroke()
      }
    case .warning:
      tile(tall, radius: 1.5, alpha: 1)
      tile(upper, radius: 1.25, alpha: 0.8)
      tile(NSRect(x: 11.375, y: 8.5, width: 1.75, height: 3.5), radius: 0.6, alpha: 1)
      NSBezierPath(ovalIn: NSRect(x: 12.25 - 0.95, y: 13.6 - 0.95, width: 1.9, height: 1.9)).fill()
    case .paused:
      NSColor.black.setStroke()
      let frame = NSBezierPath(roundedRect: NSRect(x: 1.75, y: 2.75, width: 12.5, height: 10.5), xRadius: 2, yRadius: 2)
      frame.lineWidth = 1.5
      frame.stroke()
      tile(NSRect(x: 5.5, y: 5.5, width: 1.75, height: 5), radius: 0.5, alpha: 1)
      tile(NSRect(x: 8.75, y: 5.5, width: 1.75, height: 5), radius: 0.5, alpha: 1)
    }
  }
}
