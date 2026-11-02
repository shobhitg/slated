import SwiftUI

/// A System Settings-style icon: a white SF Symbol on a tinted squircle.
struct IconTile: View {
  let symbol: String
  var tint: Color = Theme.accent
  var size: CGFloat = 28
  /// Uses the accent gradient instead of `tint`.
  var gradient = false

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
    Image(systemName: symbol)
      .font(.system(size: size * 0.5, weight: .semibold))
      .foregroundStyle(.white)
      .frame(width: size, height: size)
      .background {
        if gradient {
          shape.fill(Theme.accentGradient)
        } else {
          shape.fill(LinearGradient(colors: [tint.opacity(0.82), tint], startPoint: .top, endPoint: .bottom))
        }
      }
      .overlay(shape.strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
      .shadow(color: (gradient ? Theme.accent : tint).opacity(0.25), radius: size * 0.12, y: size * 0.04)
  }
}

/// A small capsule with a colored dot (or symbol) and label: "Active", "Duplicate"…
struct StatusPill: View {
  let text: String
  let color: Color
  var symbol: String?

  var body: some View {
    HStack(spacing: 5) {
      if let symbol {
        Image(systemName: symbol).font(.system(size: 9, weight: .bold))
      } else {
        Circle().fill(color).frame(width: 6, height: 6)
      }
      Text(text).font(.system(size: 11, weight: .semibold))
    }
    .lineLimit(1)
    .padding(.horizontal, 8)
    .padding(.vertical, 3.5)
    .foregroundStyle(color)
    .background(color.opacity(0.12), in: Capsule())
    .overlay(Capsule().strokeBorder(color.opacity(0.22), lineWidth: 0.5))
  }
}

/// A small status dot with a soft halo, for dense lists.
struct StatusDot: View {
  let color: Color
  var size: CGFloat = 7

  var body: some View {
    Circle()
      .fill(color)
      .frame(width: size, height: size)
      .background(Circle().fill(color.opacity(0.25)).frame(width: size + 5, height: size + 5))
  }
}

/// The title block at the top of each settings pane. In a compact pane the subtitle gets its own
/// line under the title row, so the accessory (buttons, switches) never squeezes or clips it.
struct PaneHeader<Accessory: View>: View {
  let pane: SettingsPane
  let subtitle: String
  @ViewBuilder var accessory: Accessory
  @Environment(\.compactPane) private var compact

  var body: some View {
    if compact {
      VStack(alignment: .leading, spacing: 8) {
        HStack(alignment: .center, spacing: 12) {
          IconTile(symbol: pane.symbol, tint: pane.tint, size: 32, gradient: pane == .overview)
          Text(pane.title)
            .font(.system(size: 20, weight: .bold))
            .tracking(-0.3)
            .lineLimit(1)
            .layoutPriority(1)
          Spacer(minLength: 8)
          accessory
        }
        Text(subtitle)
          .font(.system(size: 12.5))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    } else {
      wide
    }
  }

  private var wide: some View {
    HStack(alignment: .center, spacing: 14) {
      IconTile(symbol: pane.symbol, tint: pane.tint, size: 38, gradient: pane == .overview)
      VStack(alignment: .leading, spacing: 2) {
        Text(pane.title)
          .font(.system(size: 22, weight: .bold))
          .tracking(-0.3)
        Text(subtitle)
          .font(.system(size: 13))
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
      Spacer(minLength: 12)
      accessory
    }
  }
}

extension PaneHeader where Accessory == EmptyView {
  init(pane: SettingsPane, subtitle: String) {
    self.init(pane: pane, subtitle: subtitle) { EmptyView() }
  }
}

/// A small uppercase-free section title with an optional symbol and trailing accessory.
struct SectionHeader<Accessory: View>: View {
  let title: String
  var symbol: String?
  @ViewBuilder var accessory: Accessory

  var body: some View {
    HStack(spacing: 6) {
      if let symbol {
        Image(systemName: symbol)
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(Theme.accent)
      }
      Text(title)
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.primary.opacity(0.85))
      Spacer(minLength: 8)
      accessory
    }
    .padding(.horizontal, 4)
  }
}

extension SectionHeader where Accessory == EmptyView {
  init(_ title: String, symbol: String? = nil) {
    self.init(title: title, symbol: symbol) { EmptyView() }
  }
}

/// A titled card of settings rows. Separate rows with `CardDivider()`.
struct SettingsCard<Content: View>: View {
  var title: String?
  var symbol: String?
  var footer: String?
  @ViewBuilder var content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let title { SectionHeader(title, symbol: symbol) }
      VStack(alignment: .leading, spacing: 0) { content }
        .cardStyle(padding: 0)
      if let footer {
        Text(footer)
          .font(.system(size: 11.5))
          .foregroundStyle(.secondary)
          .padding(.horizontal, 6)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

struct CardDivider: View {
  var inset: CGFloat = 16

  var body: some View {
    Rectangle().fill(Theme.hairline).frame(height: 0.5).padding(.leading, inset)
  }
}

/// One row in a settings card: optional icon, title, subtitle, trailing control.
struct SettingRow<Trailing: View>: View {
  let title: String
  var subtitle: String?
  var symbol: String?
  var tint: Color = Theme.accent
  @ViewBuilder var trailing: Trailing

  var body: some View {
    HStack(spacing: 12) {
      if let symbol { IconTile(symbol: symbol, tint: tint, size: 26) }
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.system(size: 13, weight: .medium))
        if let subtitle {
          Text(subtitle)
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      Spacer(minLength: 16)
      // The control keeps its natural width and the text wraps beside it: an even split of the row left
      // wide controls (shortcut recorders) narrower than they can be, pushing the card past its column.
      trailing.fixedSize(horizontal: true, vertical: false)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 11)
  }
}

/// A switch row: the most common setting.
struct ToggleRow: View {
  let title: String
  var subtitle: String?
  var symbol: String?
  var tint: Color = Theme.accent
  @Binding var isOn: Bool

  var body: some View {
    SettingRow(title: title, subtitle: subtitle, symbol: symbol, tint: tint) {
      Toggle(title, isOn: $isOn)
        .labelsHidden()
        .toggleStyle(.switch)
        .controlSize(.small)
    }
  }
}

/// A label/value line for read-only facts.
struct FactRow: View {
  let label: String
  let value: String
  var monospaced = false

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      Text(label).foregroundStyle(.secondary)
      Spacer(minLength: 12)
      Text(value)
        .font(monospaced ? .system(size: 12, design: .monospaced) : .system(size: 13))
        .textSelection(.enabled)
        .lineLimit(1)
        .truncationMode(.middle)
    }
    .font(.system(size: 13))
    .padding(.horizontal, 16)
    .padding(.vertical, 9)
  }
}

extension SettingsPane {
  var symbol: String {
    switch self {
    case .getStarted: return "flag.checkered"
    case .overview: return "sparkles"
    case .windows: return "macwindow.on.rectangle"
    case .hotstrings: return "text.insert"
    case .clipboard: return "list.clipboard"
    case .automation: return "cursorarrow.click.2"
    case .keyboard: return "keyboard"
    case .layouts: return "rectangle.3.group"
    case .slate: return "doc.text.magnifyingglass"
    case .general: return "gearshape"
    case .about: return "info"
    }
  }

  var tint: Color {
    switch self {
    case .getStarted: return Color(hex: 0x1FA463)
    case .overview: return Theme.accent
    case .windows: return Color(hex: 0x2F7BF5)
    case .hotstrings: return Color(hex: 0xF08A24)
    case .clipboard: return Color(hex: 0xE5507F)
    // Matches the Mouse & Keys actions it's about.
    case .automation: return ActionKind.Category.input.tint
    case .keyboard: return Color(hex: 0x7A5AF8)
    case .layouts: return Color(hex: 0x14A89A)
    case .slate: return Color(hex: 0x4F5BD5)
    case .general: return Color(hex: 0x8A8A93)
    case .about: return Color(hex: 0x6E6E78)
    }
  }
}
