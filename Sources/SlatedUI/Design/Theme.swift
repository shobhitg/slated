import AppKit
import SwiftUI

/// Slated's visual language: one accent gradient used sparingly, quiet neutral surfaces, soft depth.
///
/// Colors are defined for light and dark appearance explicitly (instead of leaning on system colors
/// alone) so cards read as *raised* in dark mode too, where `controlBackgroundColor` is darker than
/// the window.
enum Theme {
  // MARK: Accent

  /// The solid accent, for tints (toggles, selection, links).
  static let accent = Color(red: 0.42, green: 0.37, blue: 0.99)
  static let accentStops: [Color] = [
    Color(red: 0.29, green: 0.55, blue: 1.00),
    Color(red: 0.45, green: 0.38, blue: 1.00),
    Color(red: 0.76, green: 0.40, blue: 0.98),
  ]
  /// The signature gradient: blue → violet → orchid.
  static let accentGradient = LinearGradient(
    colors: accentStops, startPoint: .topLeading, endPoint: .bottomTrailing)
  static let accentGradientHorizontal = LinearGradient(
    colors: accentStops, startPoint: .leading, endPoint: .trailing)

  // MARK: Surfaces

  static let paneBackground = Color.adaptive(light: 0xF6F6F8, dark: 0x1B1B1E)
  static let sidebarBackground = Color.adaptive(light: 0xEDEDF0, dark: 0x232326)
  /// A count pinned to an icon in the narrow sidebar: opaque, so it reads over the icon.
  static let railBadge = Color.adaptive(light: 0xD6D6DC, dark: 0x4A4A51)
  static let cardBackground = Color.adaptive(light: 0xFFFFFF, dark: 0x25252A)
  static let cardStroke = Color.adaptive(light: 0x000000, lightAlpha: 0.07, dark: 0xFFFFFF, darkAlpha: 0.07)
  /// Wells inside cards: input backgrounds, preview stages, inactive chips.
  static let well = Color.adaptive(light: 0x000000, lightAlpha: 0.035, dark: 0xFFFFFF, darkAlpha: 0.045)
  static let wellStroke = Color.adaptive(light: 0x000000, lightAlpha: 0.06, dark: 0xFFFFFF, darkAlpha: 0.06)
  static let hairline = Color.adaptive(light: 0x000000, lightAlpha: 0.08, dark: 0xFFFFFF, darkAlpha: 0.08)
  static let cardShadow = Color.adaptive(light: 0x000000, lightAlpha: 0.06, dark: 0x000000, darkAlpha: 0.35)
  static let selection = Color.adaptive(light: 0x6B5EFC, lightAlpha: 0.10, dark: 0x8C80FF, darkAlpha: 0.16)

  // MARK: Keycaps

  static let keycapTop = Color.adaptive(light: 0xFFFFFF, dark: 0x4A4A51)
  static let keycapBottom = Color.adaptive(light: 0xF0F0F3, dark: 0x3A3A40)
  static let keycapStroke = Color.adaptive(light: 0x000000, lightAlpha: 0.14, dark: 0xFFFFFF, darkAlpha: 0.10)
  static let keycapEdge = Color.adaptive(light: 0x000000, lightAlpha: 0.13, dark: 0x000000, darkAlpha: 0.55)
  static let keycapText = Color.adaptive(light: 0x3B3B42, dark: 0xF1F1F4)

  // MARK: Status

  static let positive = Color(nsColor: .systemGreen)
  static let caution = Color(nsColor: .systemOrange)
  static let critical = Color(nsColor: .systemRed)
  static let info = Color(nsColor: .systemBlue)
  static let neutral = Color(nsColor: .secondaryLabelColor)

  // MARK: Metrics

  static let cardRadius: CGFloat = 14
  static let cardPadding: CGFloat = 16
  static let paneHorizontalPadding: CGFloat = 28
  static let sectionSpacing: CGFloat = 22

  // MARK: Motion

  static let spring = Animation.spring(response: 0.42, dampingFraction: 0.82)
  static let snappy = Animation.snappy(duration: 0.22)
}

extension Color {
  /// A color that resolves per appearance. Hex values are sRGB `0xRRGGBB`.
  static func adaptive(light: UInt32, lightAlpha: CGFloat = 1, dark: UInt32, darkAlpha: CGFloat = 1) -> Color {
    Color(nsColor: NSColor.adaptive(light: light, lightAlpha: lightAlpha, dark: dark, darkAlpha: darkAlpha))
  }

  init(hex: UInt32, alpha: Double = 1) {
    self.init(
      .sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
      blue: Double(hex & 0xFF) / 255, opacity: alpha)
  }
}

extension NSColor {
  // `nonisolated` so the provider closure isn't inferred as main-actor isolated: AppKit may resolve
  // dynamic colors off the main thread while drawing.
  nonisolated static func adaptive(light: UInt32, lightAlpha: CGFloat, dark: UInt32, darkAlpha: CGFloat) -> NSColor {
    NSColor(name: nil) { appearance in
      let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
      let hex = isDark ? dark : light
      return NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: isDark ? darkAlpha : lightAlpha)
    }
  }
}

extension View {
  /// The standard raised card: rounded, hairline stroke, soft shadow.
  func cardStyle(padding: CGFloat = Theme.cardPadding, radius: CGFloat = Theme.cardRadius) -> some View {
    self
      .padding(padding)
      .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
      .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.cardStroke))
      .shadow(color: Theme.cardShadow, radius: 10, y: 3)
  }

  /// A recessed well inside a card.
  func wellStyle(radius: CGFloat = 10) -> some View {
    self
      .background(Theme.well, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
      .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.wellStroke))
  }
}
