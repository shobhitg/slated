import SlatedCore
import SwiftUI

/// The menu bar popover: status, switches, last action, recent problems and app commands.
struct MenuBarView: View {
  @Bindable var model: AppModel
  let actions: MenuBarActions

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      if !model.runtimeStatus.accessibilityGranted {
        PermissionRow(actions: actions)
          .padding(.horizontal, 10)
          .padding(.bottom, 8)
      }
      MenuDivider()
      VStack(spacing: 2) {
        SwitchRow(
          title: "Hyper Key", subtitle: model.hyperKeyEnabled ? "Caps Lock is ✦" : "Caps Lock is normal",
          symbol: "capslock.fill", tint: SettingsPane.keyboard.tint,
          isOn: Binding(get: { model.hyperKeyEnabled }, set: { model.hyperKeyEnabled = $0 }))
        SwitchRow(
          title: "Hotstrings",
          subtitle: model.runtimeStatus.hotstringsEnabled
            ? "\(model.enabledHotstringCount) expanding" : "Not expanding",
          symbol: "text.cursor", tint: SettingsPane.hotstrings.tint,
          isOn: Binding(get: { model.runtimeStatus.hotstringsEnabled }, set: { model.setHotstringsEnabled($0) }))
        SwitchRow(
          title: "Pause Slated",
          subtitle: model.runtimeStatus.paused ? "Everything is off" : "Shortcuts, Hyper and hotstrings",
          symbol: "pause.fill", tint: Color(hex: 0x8A8A93),
          isOn: Binding(get: { model.runtimeStatus.paused }, set: { model.setPaused($0) }))
      }
      .padding(6)
      MenuDivider()
      ActivitySection(model: model, actions: actions)
      MenuDivider()
      VStack(spacing: 1) {
        CommandRow(title: "Open Settings…", symbol: "gearshape", shortcut: "⌘,") { actions.openSettings() }
          .keyboardShortcut(",", modifiers: .command)
        CommandRow(title: "Reload Configuration", symbol: "arrow.clockwise", shortcut: "⌘R") { model.reload() }
          .keyboardShortcut("r", modifiers: .command)
        CommandRow(title: "Quit Slated", symbol: "power", shortcut: "⌘Q") {
          model.saveNow()
          actions.quit()
        }
        .keyboardShortcut("q", modifiers: .command)
      }
      .padding(6)
    }
    .frame(width: SlatedUI.menuBarWidth)
    .environment(model)
    .tint(Theme.accent)
    .onAppear { model.refresh() }
  }

  private var header: some View {
    HStack(spacing: 11) {
      SlatedMark(size: 34)
      VStack(alignment: .leading, spacing: 2) {
        Text("Slated").font(.system(size: 14, weight: .semibold))
        Text(summary).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
      }
      Spacer(minLength: 8)
      let state = self.state
      StatusPill(text: state.text, color: state.color)
    }
    .padding(.horizontal, 14)
    .padding(.top, 14)
    .padding(.bottom, 12)
  }

  private var state: (text: String, color: Color) {
    if model.runtimeStatus.paused { return ("Paused", Theme.neutral) }
    if !model.runtimeStatus.accessibilityGranted { return ("Needs access", Theme.caution) }
    return ("Running", Theme.positive)
  }

  private var summary: String {
    let shortcuts = model.activeBindingCount
    let hotstrings = model.runtimeStatus.hotstringsEnabled ? model.enabledHotstringCount : 0
    return "\(shortcuts) shortcut\(shortcuts == 1 ? "" : "s") · \(hotstrings) hotstring\(hotstrings == 1 ? "" : "s")"
  }
}

private struct MenuDivider: View {
  var body: some View {
    Rectangle().fill(Theme.hairline).frame(height: 0.5).padding(.horizontal, 12)
  }
}

private struct PermissionRow: View {
  let actions: MenuBarActions
  @Environment(AppModel.self) private var model

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "hand.raised.fill")
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(Theme.caution)
      VStack(alignment: .leading, spacing: 1) {
        Text("Accessibility access needed").font(.system(size: 12, weight: .semibold))
        Text("Windows can't move until you allow it.").font(.system(size: 11)).foregroundStyle(.secondary)
      }
      Spacer(minLength: 6)
      Button("Allow…") {
        if let showOnboarding = actions.showOnboarding { showOnboarding() } else { model.requestAccessibility() }
      }
      .buttonStyle(.soft)
      .controlSize(.small)
    }
    .padding(10)
    .background(Theme.caution.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.caution.opacity(0.22), lineWidth: 0.6))
  }
}

private struct SwitchRow: View {
  let title: String
  let subtitle: String
  let symbol: String
  let tint: Color
  @Binding var isOn: Bool

  var body: some View {
    HStack(spacing: 10) {
      IconTile(symbol: symbol, tint: tint, size: 26)
      VStack(alignment: .leading, spacing: 1) {
        Text(title).font(.system(size: 13, weight: .medium))
        Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
      }
      Spacer(minLength: 8)
      Toggle(title, isOn: $isOn)
        .labelsHidden()
        .toggleStyle(.switch)
        .controlSize(.small)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .contentShape(Rectangle())
    .onTapGesture { isOn.toggle() }
  }
}

/// The last action, then recent problems: failed hotkeys, Slate file errors and the last error.
private struct ActivitySection: View {
  @Bindable var model: AppModel
  let actions: MenuBarActions

  var body: some View {
    let problems = self.problems
    VStack(alignment: .leading, spacing: 6) {
      Text("Activity")
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
      HStack(spacing: 10) {
        Image(systemName: "bolt.fill")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(Theme.accentGradient)
          .frame(width: 22, height: 22)
          .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        VStack(alignment: .leading, spacing: 1) {
          Text(model.runtimeStatus.lastAction ?? "Nothing yet").font(.system(size: 12.5, weight: .medium)).lineLimit(1)
          Text(model.runtimeStatus.lastAction == nil ? "Use a shortcut and it shows up here" : "Last action")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        Spacer()
      }
      .padding(.horizontal, 8)
      ForEach(problems.prefix(3)) { problem in
        Button {
          problem.open(model)
          actions.openSettings()
        } label: {
          HStack(alignment: .top, spacing: 10) {
            Image(systemName: problem.symbol)
              .font(.system(size: 11, weight: .semibold))
              .foregroundStyle(problem.color)
              .frame(width: 22, height: 22)
              .background(problem.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
              Text(problem.title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
              Text(problem.detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(MenuRowStyle())
      }
      if problems.count > 3 {
        Button("\(problems.count - 3) more in Settings…") {
          model.selectedPane = .overview
          actions.openSettings()
        }
        .buttonStyle(.link)
        .font(.system(size: 11.5))
        .padding(.horizontal, 8)
      }
    }
    .padding(.horizontal, 6)
    .padding(.vertical, 10)
  }

  struct Problem: Identifiable {
    let id: String
    let title: String
    let detail: String
    let symbol: String
    let color: Color
    let open: @MainActor (AppModel) -> Void
  }

  private var problems: [Problem] {
    var problems: [Problem] = []
    let status = model.runtimeStatus
    for binding in model.configuration.bindings where binding.enabled {
      let key = BindingStatusKey.key(binding.keys, modal: binding.modal)
      if case .failed(let reason) = status.hotkeys[key] {
        problems.append(
          Problem(
            id: "binding-\(binding.id)", title: "\(BindingTitle.title(for: binding)) · \(binding.keys.display())",
            detail: reason, symbol: "xmark.octagon.fill", color: Theme.critical,
            open: { model in
              model.selectedPane = .windows
              model.selectedBinding = .slated(binding.id)
            }))
      }
    }
    for source in model.sources where source.loaded {
      for binding in source.bindings {
        if case .failed(let reason) = status.hotkeys[binding.id] {
          problems.append(
            Problem(
              id: "source-\(source.path)-\(binding.id)", title: "\(source.fileName) · \(binding.keys.display())",
              detail: reason, symbol: "xmark.octagon.fill", color: Theme.critical,
              open: { model in
                model.selectedPane = .windows
                model.selectedBinding = .source(path: source.path, id: binding.id)
              }))
        }
      }
      for (index, diagnostic) in source.diagnostics.enumerated() where diagnostic.severity == .error {
        problems.append(
          Problem(
            id: "diag-\(source.path)-\(index)",
            title: source.fileName + (diagnostic.line.map { " · line \($0)" } ?? ""), detail: diagnostic.message,
            symbol: "doc.badge.ellipsis", color: Theme.caution, open: { model in model.selectedPane = .slate }))
      }
    }
    if let error = status.lastError {
      problems.insert(
        Problem(
          id: "last-error", title: "Last problem", detail: error, symbol: "exclamationmark.triangle.fill",
          color: Theme.caution, open: { model in model.selectedPane = .overview }), at: 0)
    }
    return problems
  }
}

private struct CommandRow: View {
  let title: String
  let symbol: String
  let shortcut: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 10) {
        Image(systemName: symbol)
          .font(.system(size: 12, weight: .medium))
          .frame(width: 18)
          .foregroundStyle(.secondary)
        Text(title).font(.system(size: 13))
        Spacer()
        Text(shortcut).font(.system(size: 12)).foregroundStyle(.tertiary)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(MenuRowStyle())
  }
}

/// Native-menu-like rows: a soft accent highlight on hover.
private struct MenuRowStyle: ButtonStyle {
  @State private var hovering = false

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .padding(.horizontal, 8)
      .padding(.vertical, 6)
      .background(
        RoundedRectangle(cornerRadius: 7, style: .continuous)
          .fill(Theme.accent.opacity(configuration.isPressed ? 0.2 : (hovering ? 0.1 : 0)))
      )
      .onHover { hovering = $0 }
      .animation(.easeOut(duration: 0.12), value: hovering)
  }
}
