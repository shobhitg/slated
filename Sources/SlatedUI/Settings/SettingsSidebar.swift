import SwiftUI

/// The settings sidebar: brand header, panes with live counts and warnings, and a save status line.
struct SettingsSidebar: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    List(selection: selection) {
      SidebarHeader()
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
      SaveStatusFooter()
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

  private func row(_ pane: SettingsPane) -> some View {
    HStack(spacing: 9) {
      IconTile(symbol: pane.symbol, tint: pane.tint, size: 22, gradient: pane == .overview)
      Text(pane.title)
        .font(.system(size: 13))
        .lineLimit(1)
      Spacer(minLength: 4)
      badge(for: pane)
    }
    .padding(.vertical, 1)
    .tag(pane)
    .accessibilityLabel(pane.title)
  }

  @ViewBuilder private func badge(for pane: SettingsPane) -> some View {
    switch pane {
    case .getStarted where !model.runtimeStatus.accessibilityGranted:
      Image(systemName: "exclamationmark.circle.fill").font(.system(size: 11)).foregroundStyle(Theme.caution)
    case .getStarted where !model.setupFinished:
      SidebarBadge(text: "\(model.getStartedStep.rawValue + 1) of \(GetStartedStep.allCases.count)")
    case .windows where model.problemBindingCount > 0:
      SidebarBadge(text: "\(model.problemBindingCount)", color: Theme.caution)
    case .windows:
      SidebarBadge(text: "\(model.configuration.bindings.count)")
    case .hotstrings:
      SidebarBadge(text: "\(model.configuration.hotstrings.count)")
    case .clipboard where !model.configuration.clipboard.enabled:
      SidebarBadge(text: "Off")
    case .clipboard where !model.clipboardItems.isEmpty:
      SidebarBadge(text: "\(model.clipboardItems.count)")
    case .automation where !model.activeAutomations.isEmpty:
      HStack(spacing: 4) {
        LiveDot(size: 5)
        Text("\(model.activeAutomations.count)")
          .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
          .foregroundStyle(Theme.critical)
      }
      .padding(.horizontal, 6)
      .padding(.vertical, 1.5)
      .background(Theme.critical.opacity(0.12), in: Capsule())
      .help("Automations running now")
    case .automation where !model.automationBindings.isEmpty:
      SidebarBadge(text: "\(model.automationBindings.count)")
    case .layouts:
      SidebarBadge(text: "\(model.configuration.layouts.count)")
    case .overview where !model.runtimeStatus.accessibilityGranted:
      Image(systemName: "exclamationmark.circle.fill").font(.system(size: 11)).foregroundStyle(Theme.caution)
    default:
      EmptyView()
    }
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

private struct SidebarBadge: View {
  let text: String
  var color: Color?

  var body: some View {
    Text(text)
      .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
      .foregroundStyle(color ?? .secondary)
      .padding(.horizontal, 6)
      .padding(.vertical, 1.5)
      .background((color ?? Color.primary).opacity(color == nil ? 0.07 : 0.14), in: Capsule())
  }
}

/// The app's mark, name and overall state at the top of the sidebar.
private struct SidebarHeader: View {
  @Environment(AppModel.self) private var model

  var body: some View {
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
  @Environment(AppModel.self) private var model

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: symbol).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(color)
      Text(text).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 12)
    .help(help)
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
