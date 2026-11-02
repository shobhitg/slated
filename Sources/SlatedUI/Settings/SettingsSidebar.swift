import SwiftUI

/// The settings sidebar: brand header, panes with live counts and warnings, and a save status line.
/// In a narrow window (`rail`) it's a column of icons: names in tooltips, counts as small numbers.
struct SettingsSidebar: View {
  var rail = false
  @Environment(AppModel.self) private var model

  var body: some View {
    List(selection: selection) {
      SidebarHeader(rail: rail)
        .listRowSeparator(.hidden)
        .selectionDisabled()
      ForEach(Self.sections(showingGetStarted: model.showsGetStarted), id: \.self) { panes in
        Section {
          ForEach(panes) { row($0) }
        }
      }
    }
    .listStyle(.sidebar)
    .safeAreaInset(edge: .bottom, spacing: 0) {
      SaveStatusFooter(rail: rail)
    }
    .withoutScrollEdgeEffect()
  }

  /// The panes in the sidebar, by section, top to bottom. Get Started leads while it's shown.
  static func sections(showingGetStarted: Bool) -> [[SettingsPane]] {
    (showingGetStarted ? [[.getStarted]] : []) + [
      [.overview, .windows, .hotstrings, .clipboard, .automation, .keyboard, .layouts, .slate], [.general, .about],
    ]
  }

  private var selection: Binding<SettingsPane?> {
    Binding(get: { model.selectedPane }, set: { if let pane = $0 { model.selectedPane = pane } })
  }

  @ViewBuilder private func row(_ pane: SettingsPane) -> some View {
    let badge = badge(for: pane)
    if rail {
      IconTile(symbol: pane.symbol, tint: pane.tint, size: 24, gradient: pane == .overview)
        .overlay(alignment: .topTrailing) {
          if let badge { RailBadge(badge: badge).offset(x: 9, y: -6) }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .tag(pane)
        .help(badge.map { "\(pane.title): \($0.spoken)" } ?? pane.title)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(pane.title)
        .accessibilityValue(badge?.spoken ?? "")
    } else {
      HStack(spacing: 9) {
        IconTile(symbol: pane.symbol, tint: pane.tint, size: 22, gradient: pane == .overview)
        Text(pane.title)
          .font(.system(size: 13))
          .lineLimit(1)
        Spacer(minLength: 4)
        if let badge { FullBadge(badge: badge) }
      }
      .padding(.vertical, 1)
      .tag(pane)
      .accessibilityLabel(pane.title)
    }
  }

  private func badge(for pane: SettingsPane) -> SidebarBadge? {
    switch pane {
    case .getStarted where !model.runtimeStatus.accessibilityGranted:
      return .attention("Needs permission")
    case .getStarted where !model.setupFinished:
      let step = model.getStartedStep.rawValue + 1
      let total = GetStartedStep.allCases.count
      return .text("\(step) of \(total)", short: "\(step)/\(total)", spoken: "Step \(step) of \(total)")
    case .windows where model.problemBindingCount > 0:
      let count = model.problemBindingCount
      return .text("\(count)", color: Theme.caution, spoken: count == 1 ? "1 problem" : "\(count) problems")
    case .windows:
      return .count(model.configuration.bindings.count, noun: "shortcut")
    case .hotstrings:
      return .count(model.configuration.hotstrings.count, noun: "hotstring")
    case .clipboard where !model.configuration.clipboard.enabled:
      return .text("Off", spoken: "Off")
    case .clipboard where !model.clipboardItems.isEmpty:
      return .count(model.clipboardItems.count, noun: "item")
    case .automation where !model.activeAutomations.isEmpty:
      return .live(model.activeAutomations.count)
    case .automation where !model.automationBindings.isEmpty:
      return .count(model.automationBindings.count, noun: "automation")
    case .layouts:
      return .count(model.configuration.layouts.count, noun: "layout")
    case .overview where !model.runtimeStatus.accessibilityGranted:
      return .attention("Needs permission")
    default:
      return nil
    }
  }
}

/// What a sidebar row shows after its name: a count, a warning, or automations running.
private enum SidebarBadge {
  case attention(String)
  case text(String, short: String? = nil, color: Color? = nil, spoken: String)
  case live(Int)

  static func count(_ count: Int, noun: String) -> SidebarBadge {
    .text("\(count)", spoken: count == 1 ? "1 \(noun)" : "\(count) \(noun)s")
  }

  /// For tooltips and VoiceOver.
  var spoken: String {
    switch self {
    case .attention(let text): return text
    case .text(_, _, _, let spoken): return spoken
    case .live(let count): return count == 1 ? "1 automation running" : "\(count) automations running"
    }
  }
}

private struct FullBadge: View {
  let badge: SidebarBadge

  var body: some View {
    switch badge {
    case .attention:
      Image(systemName: "exclamationmark.circle.fill").font(.system(size: 11)).foregroundStyle(Theme.caution)
    case .text(let text, _, let color, _):
      Text(text)
        .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
        .foregroundStyle(color ?? .secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 1.5)
        .background((color ?? Color.primary).opacity(color == nil ? 0.07 : 0.14), in: Capsule())
    case .live(let count):
      HStack(spacing: 4) {
        LiveDot(size: 5)
        Text("\(count)")
          .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
          .foregroundStyle(Theme.critical)
      }
      .padding(.horizontal, 6)
      .padding(.vertical, 1.5)
      .background(Theme.critical.opacity(0.12), in: Capsule())
      .help("Automations running now")
    }
  }
}

/// A badge pinned to a rail icon's corner: small, opaque and ringed in the sidebar's color so it reads
/// over the icon.
private struct RailBadge: View {
  let badge: SidebarBadge

  var body: some View {
    Group {
      switch badge {
      case .attention:
        Image(systemName: "exclamationmark.circle.fill")
          .font(.system(size: 11))
          .foregroundStyle(.white, Theme.caution)
      case .text(let text, let short, let color, _):
        Text(short ?? text)
          .font(.system(size: 9, weight: .bold).monospacedDigit())
          .foregroundStyle(color == nil ? Color.primary.opacity(0.75) : .white)
          .padding(.horizontal, 4)
          .frame(minWidth: 15, minHeight: 14)
          .background(color ?? Theme.railBadge, in: Capsule())
      case .live(let count):
        HStack(spacing: 2) {
          Circle().fill(.white).frame(width: 4, height: 4)
          Text("\(count)").font(.system(size: 9, weight: .bold).monospacedDigit())
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 4)
        .frame(minHeight: 14)
        .background(Theme.critical, in: Capsule())
      }
    }
    .padding(1.5)
    .background(Theme.sidebarBackground, in: Capsule())
    .fixedSize()
  }
}

extension View {
  /// Turns off macOS 26's scroll edge effect (the blur where content scrolls under the title bar or a
  /// bar inset into the scroll view), which the window server draws. The sidebar once showed up empty
  /// on screen; it now leaves nothing to the window server, and its short list rarely scrolls anyway.
  @ViewBuilder func withoutScrollEdgeEffect() -> some View {
    if #available(macOS 26, *) {
      scrollEdgeEffectHidden(true, for: .all)
    } else {
      self
    }
  }
}

/// The app's mark, name and overall state at the top of the sidebar.
private struct SidebarHeader: View {
  var rail = false
  @Environment(AppModel.self) private var model

  var body: some View {
    if rail {
      SlatedMark(size: 30)
        .overlay(alignment: .bottomTrailing) {
          Circle().fill(state.color).frame(width: 8, height: 8)
            .padding(1.5)
            .background(Theme.sidebarBackground, in: Circle())
            .offset(x: 3, y: 3)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .help("Slated: \(state.text)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Slated: \(state.text)")
    } else {
      full
    }
  }

  private var full: some View {
    HStack(spacing: 10) {
      SlatedMark(size: 32)
      VStack(alignment: .leading, spacing: 2) {
        Text("Slated").font(.system(size: 14, weight: .semibold))
        HStack(spacing: 5) {
          Circle().fill(state.color).frame(width: 6, height: 6)
          Text(state.text).font(.system(size: 11)).foregroundStyle(.secondary)
        }
      }
    }
    .padding(.vertical, 6)
    .padding(.bottom, 4)
  }

  private var state: (text: String, color: Color) {
    let status = model.runtimeStatus
    if status.paused { return ("Paused", Theme.caution) }
    if !status.accessibilityGranted { return ("Needs permission", Theme.caution) }
    return ("Running", Theme.positive)
  }
}

/// "All changes saved" and friends, so it's clear there's no Save button to look for.
private struct SaveStatusFooter: View {
  var rail = false
  @Environment(AppModel.self) private var model

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: symbol).font(.system(size: rail ? 12 : 10.5, weight: .semibold)).foregroundStyle(color)
      if !rail {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        Spacer(minLength: 0)
      }
    }
    .frame(maxWidth: rail ? .infinity : nil)
    .padding(.horizontal, rail ? 0 : 18)
    .padding(.vertical, 12)
    .help(rail && help != text ? "\(text). \(help)" : help)
    .accessibilityElement(children: .combine)
    .animation(Theme.snappy, value: model.saveState)
  }

  private var text: String {
    switch model.saveState {
    case .saved: return "All changes saved"
    case .pending: return "Saving…"
    case .partiallySaved(let count): return count == 1 ? "1 item has errors" : "\(count) items have errors"
    case .failed: return "Couldn't save"
    case .blocked: return "Saving paused"
    }
  }

  private var symbol: String {
    switch model.saveState {
    case .saved: return "checkmark.circle.fill"
    case .pending: return "arrow.triangle.2.circlepath"
    case .partiallySaved, .failed, .blocked: return "exclamationmark.triangle.fill"
    }
  }

  private var color: Color {
    switch model.saveState {
    case .saved: return Theme.positive
    case .pending: return .secondary
    case .partiallySaved, .blocked: return Theme.caution
    case .failed: return Theme.critical
    }
  }

  private var help: String {
    switch model.saveState {
    case .saved: return "Changes are saved to config.json and settings.json as you make them."
    case .pending: return "Saving…"
    case .partiallySaved: return "Items with errors keep their last saved version until they're fixed."
    case .failed(let message): return message
    case .blocked: return "\(model.unreadableFileName) can't be read, so Slated won't overwrite it."
    }
  }
}
