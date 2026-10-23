import SlatedCore
import SwiftUI

/// Slated's mark: tiled window panes on the accent gradient squircle.
struct SlatedMark: View {
  var size: CGFloat = 32
  /// Adds a soft colored glow behind the mark (hero placements).
  var glow = false

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
    let inset = size * 0.2
    let gap = size * 0.07
    let paneRadius = size * 0.07
    let inner = size - inset * 2
    let leftWidth = (inner - gap) * 0.56
    let rightWidth = inner - gap - leftWidth
    let halfHeight = (inner - gap) / 2

    ZStack {
      if glow {
        shape.fill(Theme.accentGradient)
          .blur(radius: size * 0.22)
          .opacity(0.55)
          .offset(y: size * 0.08)
      }
      shape.fill(Theme.accentGradient)
      shape.fill(LinearGradient(colors: [.white.opacity(0.28), .clear], startPoint: .top, endPoint: .center))
      shape.strokeBorder(.white.opacity(0.25), lineWidth: max(0.5, size * 0.012))
      HStack(spacing: gap) {
        RoundedRectangle(cornerRadius: paneRadius, style: .continuous)
          .fill(.white)
          .frame(width: leftWidth, height: inner)
        VStack(spacing: gap) {
          RoundedRectangle(cornerRadius: paneRadius, style: .continuous)
            .fill(.white.opacity(0.78))
            .frame(width: rightWidth, height: halfHeight)
          RoundedRectangle(cornerRadius: paneRadius, style: .continuous)
            .fill(.white.opacity(0.5))
            .frame(width: rightWidth, height: halfHeight)
        }
      }
      .shadow(color: .black.opacity(0.12), radius: size * 0.03, y: size * 0.015)
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }
}

/// A miniature screen with the region a placement covers, e.g. the left half.
struct RegionGlyph: View {
  let region: CGRect
  var width: CGFloat = 24
  var height: CGFloat = 16
  var highlighted = false

  var body: some View {
    let inner = CGSize(width: width - 4, height: height - 4)
    ZStack(alignment: .topLeading) {
      RoundedRectangle(cornerRadius: 3.5, style: .continuous)
        .fill(Theme.well)
      RoundedRectangle(cornerRadius: 3.5, style: .continuous)
        .strokeBorder(Color.primary.opacity(highlighted ? 0.0 : 0.28), lineWidth: 1)
      RoundedRectangle(cornerRadius: 1.8, style: .continuous)
        .fill(Theme.accentGradient)
        .frame(width: max(2, region.width * inner.width - 0.5), height: max(2, region.height * inner.height - 0.5))
        .offset(x: 2 + region.minX * inner.width + 0.25, y: 2 + region.minY * inner.height + 0.25)
    }
    .frame(width: width, height: height)
    .overlay {
      if highlighted {
        RoundedRectangle(cornerRadius: 3.5, style: .continuous).strokeBorder(Theme.accent, lineWidth: 1.2)
      }
    }
  }
}

/// The glyph for any action: its preset region when it has one, else the operation's symbol.
struct ActionGlyph: View {
  let action: Action
  var width: CGFloat = 24
  var height: CGFloat = 16

  var body: some View {
    if let region = WindowPresets.matching(action)?.region {
      RegionGlyph(region: region, width: width, height: height)
    } else {
      Image(systemName: WindowPresets.matching(action)?.symbol ?? ActionKind(action).symbol)
        .font(.system(size: height * 0.62, weight: .semibold))
        .foregroundStyle(Theme.accentGradient)
        .frame(width: width, height: height)
        .background(Theme.well, in: RoundedRectangle(cornerRadius: 3.5, style: .continuous))
    }
  }
}
