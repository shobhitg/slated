import SlatedCore
import SwiftUI

/// A miniature of the display arrangement with a window drawn where an action puts it.
///
/// Rects are in Slated's global top-left coordinates, which map directly onto SwiftUI's.
struct ScreenPreview: View {
  let screens: [ScreenInfo]
  /// Where the window ends up. `nil` draws no window.
  var target: CGRect?
  /// Where the window starts, drawn as a faint dashed outline.
  var origin: CGRect?
  /// Dims the screens, e.g. when the preview is unavailable.
  var dimmed = false
  var showsLabels = true
  /// More windows, each with a label (layout previews: one per app).
  var windows: [PreviewWindow] = []

  struct PreviewWindow: Hashable {
    var frame: CGRect
    var label: String
    var hue: Double
  }

  var body: some View {
    GeometryReader { proxy in
      let map = ScreenMap(screens: screens, size: proxy.size, labelHeight: showsLabels ? 18 : 0)
      ZStack(alignment: .topLeading) {
        ForEach(screens, id: \.displayID) { screen in
          let rect = map.rect(screen.frame).insetBy(dx: 2, dy: 2)
          MiniScreen(screen: screen, scale: map.scale, dimmed: dimmed)
            .frame(width: rect.width, height: rect.height)
            .offset(x: rect.minX, y: rect.minY)
          if showsLabels {
            ScreenLabel(screen: screen)
              .frame(width: max(rect.width, 60))
              .offset(x: rect.midX - max(rect.width, 60) / 2, y: rect.maxY + 5)
          }
        }
        ForEach(Array(windows.enumerated()), id: \.offset) { _, window in
          let rect = map.rect(window.frame).insetBy(dx: 1.5, dy: 1.5)
          MiniWindow(size: window.frame.size, label: window.label, hue: window.hue)
            .frame(width: max(rect.width, 6), height: max(rect.height, 6))
            .offset(x: rect.minX, y: rect.minY)
        }
        if let origin {
          let rect = map.rect(origin)
          RoundedRectangle(cornerRadius: 3, style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 2.5]))
            .foregroundStyle(.white.opacity(0.75))
            .frame(width: rect.width, height: rect.height)
            .offset(x: rect.minX, y: rect.minY)
        }
        if let target {
          let rect = map.rect(target)
          MiniWindow(size: target.size)
            .frame(width: max(rect.width, 6), height: max(rect.height, 6))
            .offset(x: rect.minX, y: rect.minY)
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
        }
      }
      .animation(Theme.spring, value: target)
    }
  }
}

/// Fits the union of all screens into the available size, centered.
private struct ScreenMap {
  let union: CGRect
  let scale: CGFloat
  let offset: CGPoint

  init(screens: [ScreenInfo], size: CGSize, labelHeight: CGFloat) {
    let union = screens.reduce(CGRect.null) { $0.union($1.frame) }
    self.union = union.isNull ? CGRect(x: 0, y: 0, width: 1, height: 1) : union
    let available = CGSize(width: max(size.width, 1), height: max(size.height - labelHeight, 1))
    scale = min(available.width / self.union.width, available.height / self.union.height)
    offset = CGPoint(
      x: (available.width - self.union.width * scale) / 2, y: (available.height - self.union.height * scale) / 2)
  }

  func rect(_ r: CGRect) -> CGRect {
    CGRect(
      x: offset.x + (r.minX - union.minX) * scale, y: offset.y + (r.minY - union.minY) * scale,
      width: r.width * scale, height: r.height * scale)
  }
}

private struct MiniScreen: View {
  let screen: ScreenInfo
  let scale: CGFloat
  let dimmed: Bool

  private static let wallpaperLight: [Color] = [Color(hex: 0x9FB6FF), Color(hex: 0xB9A8FF), Color(hex: 0xF0B8E4)]
  private static let wallpaperDark: [Color] = [Color(hex: 0x23305F), Color(hex: 0x3A2C6E), Color(hex: 0x5F2D63)]
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    let menuBar = max(2.5, (screen.visibleFrame.minY - screen.frame.minY) * scale)
    let dock = (screen.frame.maxY - screen.visibleFrame.maxY) * scale
    GeometryReader { proxy in
      ZStack(alignment: .top) {
        RoundedRectangle(cornerRadius: 3.5, style: .continuous)
          .fill(
            LinearGradient(
              colors: colorScheme == .dark ? Self.wallpaperDark : Self.wallpaperLight, startPoint: .topLeading,
              endPoint: .bottomTrailing)
          )
          .saturation(dimmed ? 0.15 : 1)
          .opacity(dimmed ? 0.55 : 1)
        Rectangle()
          .fill(.white.opacity(colorScheme == .dark ? 0.16 : 0.5))
          .frame(height: menuBar)
          .clipShape(UnevenRoundedRectangle(topLeadingRadius: 3.5, topTrailingRadius: 3.5, style: .continuous))
        if dock > 2 {
          VStack {
            Spacer()
            Capsule()
              .fill(.white.opacity(colorScheme == .dark ? 0.18 : 0.45))
              .frame(width: proxy.size.width * 0.42, height: max(2.5, dock * 0.55))
              .padding(.bottom, dock * 0.2)
          }
        }
      }
      .padding(2)
      .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color(hex: 0x17171A)))
      .overlay(
        RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(
          .white.opacity(colorScheme == .dark ? 0.12 : 0))
      )
      .shadow(color: .black.opacity(colorScheme == .dark ? 0.4 : 0.12), radius: 6, y: 3)
    }
  }
}

private struct ScreenLabel: View {
  let screen: ScreenInfo

  var body: some View {
    HStack(spacing: 4) {
      if screen.isMain {
        Image(systemName: "menubar.rectangle").font(.system(size: 8.5, weight: .semibold))
      }
      Text(screen.name).lineLimit(1).truncationMode(.middle)
    }
    .font(.system(size: 10, weight: .medium))
    .foregroundStyle(.secondary)
  }
}

/// The placed window: accent glass with traffic lights and its size (or a label).
private struct MiniWindow: View {
  /// The window's real size in points, shown when there's room and no label.
  let size: CGSize
  var label: String?
  /// Tints the window away from the accent (0…1 hue), to tell several windows apart.
  var hue: Double?

  private var fill: AnyShapeStyle {
    guard let hue else { return AnyShapeStyle(Theme.accentGradient) }
    return AnyShapeStyle(
      LinearGradient(
        colors: [
          Color(hue: hue, saturation: 0.55, brightness: 0.98), Color(hue: hue, saturation: 0.75, brightness: 0.85),
        ],
        startPoint: .topLeading, endPoint: .bottomTrailing))
  }

  var body: some View {
    GeometryReader { proxy in
      let radius = min(6, max(2.5, proxy.size.width * 0.03))
      let dot = min(5, max(2.2, proxy.size.height * 0.045))
      ZStack(alignment: .topLeading) {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
          .fill(fill)
          .opacity(0.92)
        RoundedRectangle(cornerRadius: radius, style: .continuous)
          .fill(LinearGradient(colors: [.white.opacity(0.22), .clear], startPoint: .top, endPoint: .center))
        if proxy.size.width > 24 && proxy.size.height > 16 {
          HStack(spacing: dot * 0.6) {
            Circle().fill(Color(hex: 0xFF5F57))
            Circle().fill(Color(hex: 0xFEBC2E))
            Circle().fill(Color(hex: 0x28C840))
          }
          .frame(height: dot)
          .padding(.leading, dot * 1.3)
          .padding(.top, dot * 1.3)
        }
        if let label, proxy.size.width > 30 && proxy.size.height > 22 {
          Text(label)
            .font(.system(size: 10, weight: .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if label == nil, proxy.size.width > 74 && proxy.size.height > 34 {
          Text(verbatim: "\(Int(size.width.rounded())) × \(Int(size.height.rounded()))")
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
      .overlay(
        RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(.white.opacity(0.55), lineWidth: 0.8)
      )
      .shadow(
        color: (hue.map { Color(hue: $0, saturation: 0.7, brightness: 0.9) } ?? Theme.accent).opacity(0.45), radius: 8,
        y: 2)
    }
  }
}
