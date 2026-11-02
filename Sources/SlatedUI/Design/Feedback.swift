import SwiftUI

/// An inline callout: information, a warning, an error or a success.
struct Notice<Actions: View>: View {
  enum Style {
    case info, warning, error, success

    var color: Color {
      switch self {
      case .info: return Theme.info
      case .warning: return Theme.caution
      case .error: return Theme.critical
      case .success: return Theme.positive
      }
    }

    var symbol: String {
      switch self {
      case .info: return "info.circle.fill"
      case .warning: return "exclamationmark.triangle.fill"
      case .error: return "xmark.octagon.fill"
      case .success: return "checkmark.circle.fill"
      }
    }
  }

  let style: Style
  let title: String
  var message: String?
  var symbol: String?
  @ViewBuilder var actions: Actions

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: symbol ?? style.symbol)
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(style.color)
        .frame(width: 18)
      VStack(alignment: .leading, spacing: 4) {
        LinkedText(title).font(.system(size: 12.5, weight: .semibold))
        if let message {
          LinkedText(message)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        actions
      }
      Spacer(minLength: 0)
    }
    .padding(12)
    .background(style.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(style.color.opacity(0.2), lineWidth: 0.6))
  }
}

extension Notice where Actions == EmptyView {
  init(style: Style, title: String, message: String? = nil, symbol: String? = nil) {
    self.init(style: style, title: title, message: message, symbol: symbol) { EmptyView() }
  }
}

/// A friendly empty state: a glowing symbol, a title, a sentence and actions.
struct EmptyStateView<Actions: View>: View {
  let symbol: String
  let title: String
  let message: String
  @ViewBuilder var actions: Actions

  var body: some View {
    VStack(spacing: 14) {
      ZStack {
        Circle()
          .fill(
            RadialGradient(
              colors: [Theme.accent.opacity(0.22), .clear], center: .center, startRadius: 4, endRadius: 56)
          )
          .frame(width: 112, height: 112)
        RoundedRectangle(cornerRadius: 18, style: .continuous)
          .fill(Theme.cardBackground)
          .frame(width: 60, height: 60)
          .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.cardStroke))
          .shadow(color: Theme.accent.opacity(0.18), radius: 12, y: 4)
        Image(systemName: symbol)
          .font(.system(size: 25, weight: .medium))
          .foregroundStyle(Theme.accentGradient)
      }
      .frame(height: 96)
      VStack(spacing: 6) {
        Text(title).font(.system(size: 16, weight: .semibold))
        LinkedText(message)
          .font(.system(size: 12.5))
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .frame(maxWidth: 320)
          .fixedSize(horizontal: false, vertical: true)
      }
      actions.padding(.top, 4)
    }
    .padding(32)
    .frame(maxWidth: .infinity)
  }
}

extension EmptyStateView where Actions == EmptyView {
  init(symbol: String, title: String, message: String) {
    self.init(symbol: symbol, title: title, message: message) { EmptyView() }
  }
}

/// The transient confirmation capsule at the bottom of the settings window.
struct ToastView: View {
  let toast: Toast

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: toast.symbol)
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(color)
      Text(toast.message)
        .font(.system(size: 12.5, weight: .medium))
        .lineLimit(2)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 9)
    .background(Theme.cardBackground, in: Capsule())
    .overlay(Capsule().strokeBorder(Theme.cardStroke))
    .shadow(color: .black.opacity(0.14), radius: 16, y: 6)
  }

  private var color: Color {
    switch toast.style {
    case .success: return Theme.positive
    case .info: return Theme.accent
    case .failure: return Theme.critical
    }
  }
}

/// The primary call to action: accent gradient, white label, soft glow.
struct GradientButtonStyle: ButtonStyle {
  var large = false
  /// Tighter padding, for buttons inside small cards.
  var compact = false
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      // A squeezed row wraps or truncates the text beside the button, never the button's title.
      .lineLimit(1)
      .fixedSize(horizontal: true, vertical: false)
      .font(.system(size: large ? 14 : (compact ? 12 : 12.5), weight: .semibold))
      .foregroundStyle(.white)
      .padding(.horizontal, large ? 22 : (compact ? 10 : 14))
      .frame(height: large ? 38 : (compact ? 26 : 28))
      .background {
        RoundedRectangle(cornerRadius: large ? 11 : 8, style: .continuous)
          .fill(Theme.accentGradientHorizontal)
          .overlay(
            // A soft top highlight gives the button a little volume.
            RoundedRectangle(cornerRadius: large ? 11 : 8, style: .continuous)
              .fill(LinearGradient(colors: [.white.opacity(0.18), .clear], startPoint: .top, endPoint: .center))
          )
          .overlay(
            RoundedRectangle(cornerRadius: large ? 11 : 8, style: .continuous)
              .strokeBorder(.white.opacity(0.22), lineWidth: 0.6)
          )
      }
      .shadow(color: Theme.accent.opacity(isEnabled ? 0.35 : 0), radius: large ? 10 : 6, y: large ? 4 : 2)
      .opacity(isEnabled ? 1 : 0.45)
      .scaleEffect(configuration.isPressed ? 0.97 : 1)
      .brightness(configuration.isPressed ? -0.06 : 0)
      .animation(Theme.snappy, value: configuration.isPressed)
  }
}

/// A quiet secondary button: neutral fill, hairline border.
struct SoftButtonStyle: ButtonStyle {
  var large = false
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .lineLimit(1)
      .fixedSize(horizontal: true, vertical: false)
      .font(.system(size: large ? 14 : 12.5, weight: .medium))
      .padding(.horizontal, large ? 20 : 12)
      .frame(height: large ? 38 : 28)
      .background(
        Theme.cardBackground.opacity(configuration.isPressed ? 0.6 : 1),
        in: RoundedRectangle(cornerRadius: large ? 11 : 8, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: large ? 11 : 8, style: .continuous).strokeBorder(
          Theme.cardStroke, lineWidth: 0.8)
      )
      .shadow(color: Theme.cardShadow, radius: 3, y: 1)
      .opacity(isEnabled ? 1 : 0.45)
      .scaleEffect(configuration.isPressed ? 0.98 : 1)
      .animation(Theme.snappy, value: configuration.isPressed)
  }
}

extension ButtonStyle where Self == GradientButtonStyle {
  static var gradient: GradientButtonStyle { GradientButtonStyle() }
  static var gradientLarge: GradientButtonStyle { GradientButtonStyle(large: true) }
  static var gradientCompact: GradientButtonStyle { GradientButtonStyle(compact: true) }
}

extension ButtonStyle where Self == SoftButtonStyle {
  static var soft: SoftButtonStyle { SoftButtonStyle() }
  static var softLarge: SoftButtonStyle { SoftButtonStyle(large: true) }
}
