import SlatedCore
import SwiftUI

// Clipboard pieces shared by the picker and Settings → Clipboard: a kind-aware one-line preview,
// the kind badge, a color swatch, and the fanned stack of recent items used as an illustration.

/// A clipboard item on one line, styled by what it is: a link's host, a color's swatch, code in
/// monospace, an image's size.
struct ClipPreviewLine: View {
  let item: ClipboardItem
  var fontSize: CGFloat = 13
  var lineLimit = 1
  var inverted = false

  var body: some View {
    let kind = ClipboardContent.kind(of: item.text)
    let primary: Color = inverted ? .white : .primary
    let secondary: Color = inverted ? .white.opacity(0.75) : .secondary
    HStack(spacing: 6) {
      switch kind {
      case _ where item.isImage:
        Text(item.image.map { ClipboardContent.imageTitle($0, app: nil) } ?? "")
          .font(.system(size: fontSize))
          .foregroundStyle(primary)
      case .color:
        ColorSwatch(hex: item.text.trimmingCharacters(in: .whitespacesAndNewlines), size: fontSize + 1)
        Text(item.text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased())
          .font(.system(size: fontSize - 0.5, weight: .medium, design: .monospaced))
          .foregroundStyle(primary)
      case .link:
        if let host = ClipboardContent.host(of: item.text.trimmingCharacters(in: .whitespacesAndNewlines)) {
          Text(host).font(.system(size: fontSize, weight: .semibold)).foregroundStyle(primary).layoutPriority(1)
        }
        Text(item.text.trimmingCharacters(in: .whitespacesAndNewlines))
          .font(.system(size: fontSize - 1))
          .foregroundStyle(secondary)
      default:
        Text(ClipboardContent.singleLine(item.text))
          .font(
            kind.isMonospaced
              ? .system(size: fontSize - 1, weight: .regular, design: .monospaced) : .system(size: fontSize)
          )
          .foregroundStyle(primary)
      }
    }
    .lineLimit(lineLimit)
    .truncationMode(.tail)
  }
}

/// A round swatch for `#RRGGBB` text.
struct ColorSwatch: View {
  let hex: String
  var size: CGFloat = 14

  var body: some View {
    let rgba = ClipboardContent.rgba(hex)
    Circle()
      .fill(
        rgba.map { Color(.sRGB, red: $0.red, green: $0.green, blue: $0.blue, opacity: $0.alpha) } ?? Color.gray
      )
      .frame(width: size, height: size)
      .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.6))
  }
}

/// The item's source app icon, or its kind's symbol when the app is unknown.
struct ClipSourceIcon: View {
  let item: ClipboardItem
  var size: CGFloat = 26

  var body: some View {
    if item.isImage && item.sourceApp == nil {
      Image(systemName: "photo")
        .font(.system(size: size * 0.42, weight: .semibold))
        .foregroundStyle(.secondary)
        .frame(width: size, height: size)
        .background(Theme.well, in: RoundedRectangle(cornerRadius: size * 0.25, style: .continuous))
    } else if let app = item.sourceApp {
      AppIconView(bundleID: app, size: size)
    } else {
      Image(systemName: ClipboardContent.kind(of: item.text).symbol)
        .font(.system(size: size * 0.42, weight: .semibold))
        .foregroundStyle(.secondary)
        .frame(width: size, height: size)
        .background(Theme.well, in: RoundedRectangle(cornerRadius: size * 0.25, style: .continuous))
    }
  }
}

/// "Link", "Code"… as a small capsule with the kind's symbol.
struct ClipKindBadge: View {
  let kind: ClipboardContentKind
  var inverted = false

  var body: some View {
    HStack(spacing: 4) {
      Image(systemName: kind.symbol).font(.system(size: 9, weight: .bold))
      Text(kind.title).font(.system(size: 10.5, weight: .semibold))
    }
    .foregroundStyle(inverted ? AnyShapeStyle(.white) : AnyShapeStyle(SettingsPane.clipboard.tint))
    .padding(.horizontal, 7)
    .padding(.vertical, 2.5)
    .background(
      inverted ? AnyShapeStyle(.white.opacity(0.2)) : AnyShapeStyle(SettingsPane.clipboard.tint.opacity(0.12)),
      in: Capsule())
  }
}

/// A few recent clipboard items as a fanned stack of cards, for the Clipboard pane's hero.
struct ClipboardStackArt: View {
  let items: [ClipboardItem]

  var body: some View {
    let placeholder = items.isEmpty
    let shown = Array((placeholder ? Self.placeholders : items).prefix(3))
    ZStack {
      ForEach(Array(shown.enumerated().reversed()), id: \.offset) { depth, item in
        card(item, depth: depth, placeholder: placeholder)
          .frame(width: 184 - CGFloat(depth) * 12, height: 48)
          .rotationEffect(.degrees(Double(depth) * -4))
          .offset(x: CGFloat(depth) * -6, y: CGFloat(depth) * -14)
      }
    }
    .offset(y: 14)
    .accessibilityHidden(true)
  }

  /// Opaque cards, so the ones behind never show through; their content is dimmed instead.
  private func card(_ item: ClipboardItem, depth: Int, placeholder: Bool) -> some View {
    HStack(spacing: 8) {
      ClipSourceIcon(item: item, size: 22)
      ClipPreviewLine(item: item, fontSize: 11.5, lineLimit: depth == 0 ? 2 : 1)
        .frame(maxWidth: .infinity, alignment: .leading)
      if item.pinned && depth == 0 {
        Image(systemName: "pin.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(SettingsPane.clipboard.tint)
      }
    }
    .opacity(placeholder ? 0.45 : (depth == 0 ? 1 : 0.45))
    .padding(.horizontal, 10)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    .background(Theme.cardBackground)
    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 11, style: .continuous)
        .strokeBorder(
          depth == 0 && !placeholder ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.cardStroke),
          lineWidth: depth == 0 && !placeholder ? 1.2 : 0.8)
    )
    .shadow(color: .black.opacity(depth == 0 ? 0.14 : 0.07), radius: depth == 0 ? 10 : 4, y: depth == 0 ? 4 : 1)
  }

  private static let placeholders: [ClipboardItem] = [
    ClipboardItem(text: "Something you copied", copiedAt: Date()),
    ClipboardItem(text: "https://example.com", copiedAt: Date()),
    ClipboardItem(text: "Another snippet", copiedAt: Date()),
  ]
}
