import SlatedCore
import SwiftUI

/// Status at a glance, the last thing Slated did, tips drawn from the user's own setup, and next steps.
struct OverviewPane: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    PaneScroll {
      HeroCard()
      if let report = model.slateImportNotice {
        SlateImportNoticeCard(report: report)
      }
      if model.showsMenuBarNotice {
        MenuBarNoticeCard()
      }
      if model.showsKeyRepeatLogoutNotice {
        KeyRepeatLogoutNoticeCard()
      }
      RunningAutomationsCard(hidesWhenIdle: true)
        .animation(Theme.spring, value: model.activeAutomations.isEmpty)
      VStack(alignment: .leading, spacing: 10) {
        SectionHeader("Status", symbol: "waveform.path.ecg")
        StatusGrid()
      }
      ActivityCard()
      QuickTips()
      NextSteps()
    }
  }
}

// MARK: - Slate import

/// Said once, after a first run or the move to two config files imported the Slate config: its
/// shortcuts are Slated's now, and Slated no longer reads the Slate file.
struct SlateImportNoticeCard: View {
  let report: SlateImportReport
  @Environment(AppModel.self) private var model

  var body: some View {
    Notice(style: .success, title: title, message: message, symbol: "square.and.arrow.down.fill") {
      HStack(spacing: 8) {
        Button("Show Shortcuts") { model.selectedPane = .windows }
        Button("Got It") { model.dismissSlateImportNotice() }
      }
      .buttonStyle(.soft)
      .controlSize(.small)
      .padding(.top, 4)
    }
  }

  private var title: String {
    "Your \(report.fileNames) shortcuts are now part of Slated's config"
  }

  private var message: String {
    var text =
      // file link: Notice's message (LinkedText)
      "Slated doesn't read \(report.fileNames) any more: edit them here or in ~/.config/slated/config.json."
    let skipped = report.notConverted
    if !skipped.isEmpty {
      text += " \(skipped.count) couldn't be converted: \(skipped.map(\.displayName).joined(separator: ", "))."
    }
    return text
  }
}

// MARK: - Hero

private struct HeroCard: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    HStack(alignment: .center, spacing: 20) {
      VStack(alignment: .leading, spacing: 8) {
        Text(greeting)
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(Theme.accentGradientHorizontal)
          .textCase(.uppercase)
          .tracking(0.6)
        LinkedText(headline)
          .font(.system(size: 24, weight: .bold))
          .tracking(-0.4)
        LinkedText(summary)
          .font(.system(size: 13))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        if let action = primaryAction {
          Button(action.title, action: action.run)
            .buttonStyle(.gradient)
            .padding(.top, 6)
        }
      }
      Spacer(minLength: 12)
      SlatedMark(size: 76, glow: true)
        .padding(.trailing, 8)
    }
    .padding(22)
    .background {
      ZStack {
        Theme.cardBackground
        RadialGradient(
          colors: [Theme.accentStops[1].opacity(0.16), .clear], center: .topTrailing, startRadius: 10, endRadius: 380)
        RadialGradient(
          colors: [Theme.accentStops[0].opacity(0.10), .clear], center: .bottomLeading, startRadius: 10, endRadius: 300)
      }
      .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.cardStroke))
    .shadow(color: Theme.cardShadow, radius: 14, y: 4)
  }

  private var greeting: String {
    let hour = Calendar.current.component(.hour, from: Date())
    switch hour {
    case 5..<12: return "Good morning"
    case 12..<18: return "Good afternoon"
    default: return "Good evening"
    }
  }

  private var attention: [String] {
    var items: [String] = []
    if !model.runtimeStatus.accessibilityGranted { items.append("Accessibility") }
    if model.problemBindingCount > 0 { items.append("shortcuts") }
    // file link: counted, not shown
    if model.loadError != nil { items.append("config.json") }
    return items
  }

  private var headline: String {
    // file link: LinkedText(headline)
    if model.loadError != nil { return "config.json needs a fix" }
    if model.runtimeStatus.paused { return "Slated is paused" }
    if attention.isEmpty { return "Everything's running" }
    return attention.count == 1 ? "One thing needs your attention" : "\(attention.count) things need your attention"
  }

  private var summary: String {
    let status = model.runtimeStatus
    if model.loadError != nil {
      return
        "Slated can't read \(model.unreadableFileName), so it keeps running what it last loaded. Settings are read-only until the file is fixed."
    }
    if status.paused { return "Shortcuts, the Hyper key and hotstrings are off until you resume them." }
    if !status.accessibilityGranted {
      return
        "Slated needs Accessibility access to move windows and type hotstrings. Your shortcuts are ready the moment you allow it."
    }
    var parts: [String] = []
    parts.append(model.activeBindingCount == 1 ? "1 shortcut" : "\(model.activeBindingCount) shortcuts")
    if status.hotstringsActive { parts.append("\(model.enabledHotstringCount) hotstrings") }
    if status.hyperKeyActive { parts.append("the Hyper key") }
    if model.configuration.clipboard.enabled { parts.append("clipboard history") }
    let list = ListFormatter.localizedString(byJoining: parts)
    return "\(list) \(parts.count == 1 && model.activeBindingCount == 1 ? "is" : "are") live."
  }

  private var primaryAction: (title: String, run: () -> Void)? {
    // file link: a button's title
    if model.loadError != nil { return ("Reveal config.json", { model.revealConfigurationFile() }) }
    if model.runtimeStatus.paused { return ("Resume Slated", { model.setPaused(false) }) }
    if !model.runtimeStatus.accessibilityGranted {
      return ("Grant Accessibility Access", { model.requestAccessibility() })
    }
    if model.problemBindingCount > 0 { return ("Review Shortcuts", { model.selectedPane = .windows }) }
    return nil
  }
}

// MARK: - Status grid

private struct StatusGrid: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    let status = model.runtimeStatus
    VStack(spacing: 12) {
      HStack(spacing: 12) {
        StatusTile(
          title: "Accessibility", symbol: "hand.raised.fill", tint: Color(hex: 0x2F7BF5),
          value: status.accessibilityGranted ? "Allowed" : "Not allowed",
          state: status.accessibilityGranted ? .good : .attention,
          detail: status.accessibilityGranted ? "Windows can move" : "Needed to move windows"
        ) {
          if !status.accessibilityGranted {
            Button("Allow…") { model.requestAccessibility() }
          }
        }
        StatusTile(
          title: "Hyper Key", symbol: "capslock.fill", tint: SettingsPane.keyboard.tint,
          value: model.hyperKeyEnabled ? (status.hyperKeyActive ? "On" : "Starting…") : "Off",
          state: model.hyperKeyEnabled ? (status.hyperKeyActive ? .good : .neutral) : .neutral,
          detail: model.hyperKeyEnabled
            ? "⇪ acts as \(model.configuration.keyboard.hyperModifiers.symbols)" : "Caps Lock is normal"
        ) {
          if !model.hyperKeyEnabled {
            Button("Set Up") { model.selectedPane = .keyboard }
          }
        }
        StatusTile(
          title: "Hotstrings", symbol: "text.insert", tint: SettingsPane.hotstrings.tint,
          value: status.hotstringsEnabled ? "\(model.enabledHotstringCount) active" : "Off",
          state: status.hotstringsActive ? .good : .neutral,
          detail: status.hotstringsEnabled ? "Text expansion is on" : "Turned off"
        ) { EmptyView() }
      }
      HStack(spacing: 12) {
        StatusTile(
          title: "Shortcuts", symbol: "command", tint: SettingsPane.windows.tint,
          value: "\(model.activeBindingCount) active", state: model.problemBindingCount > 0 ? .attention : .good,
          detail: shortcutDetail
        ) {
          Button(model.problemBindingCount > 0 ? "Review" : "Edit") { model.selectedPane = .windows }
        }
        StatusTile(
          title: "Config Files", symbol: "doc.text.fill", tint: SettingsPane.general.tint,
          value: model.loadError == nil ? "Up to date" : "Can't read \(model.unreadableFileName)",
          state: model.loadError == nil ? .good : .attention, detail: "config.json and settings.json"
        ) {
          Button("Show") { model.revealConfigurationFile() }
        }
      }
      HStack(spacing: 12) {
        let clipboard = model.configuration.clipboard
        StatusTile(
          title: "Clipboard", symbol: SettingsPane.clipboard.symbol, tint: SettingsPane.clipboard.tint,
          value: clipboard.enabled
            ? "\(model.clipboardItems.count) item\(model.clipboardItems.count == 1 ? "" : "s")" : "Off",
          state: clipboard.enabled ? .good : .neutral, detail: clipboardDetail
        ) {
          if clipboard.enabled {
            Button("Open") { model.showClipboardHistory() }
          } else {
            Button("Turn On") { model.selectedPane = .clipboard }
          }
        }
        let running = model.activeAutomations.count
        StatusTile(
          title: "Automation", symbol: SettingsPane.automation.symbol, tint: SettingsPane.automation.tint,
          value: running > 0 ? "\(running) running" : automationValue,
          state: running > 0 ? .live : (model.automationBindings.isEmpty ? .neutral : .good), detail: automationDetail
        ) {
          if running > 0 {
            Button("Stop") { model.stopAutomations() }
          } else {
            Button(model.automationBindings.isEmpty ? "Set Up" : "Edit") { model.selectedPane = .automation }
          }
        }
      }
    }
  }

  private var clipboardDetail: String {
    let clipboard = model.configuration.clipboard
    guard clipboard.enabled else { return "Copies aren't remembered" }
    guard let shortcut = clipboard.shortcut else { return "No shortcut: open it from here" }
    return "\(shortcut.display()) to search and paste"
  }

  private var automationValue: String {
    let count = model.automationBindings.filter(\.enabled).count
    return count == 0 ? "None yet" : "\(count) ready"
  }

  private var automationDetail: String {
    guard let stop = model.configuration.automation.stopShortcut else { return "No stop shortcut" }
    return model.activeAutomations.isEmpty ? "\(stop.display()) stops everything" : "Press \(stop.display()) to stop"
  }

  private var shortcutDetail: String {
    let hotkeys = model.runtimeStatus.hotkeys.values
    let duplicates = hotkeys.filter { $0 == .duplicate }.count
    let failed = hotkeys.filter { if case .failed = $0 { return true } else { return false } }.count
    var parts: [String] = []
    if duplicates > 0 { parts.append("\(duplicates) duplicate\(duplicates == 1 ? "" : "s")") }
    if failed > 0 { parts.append("\(failed) failed") }
    if parts.isEmpty {
      let count = model.configuration.bindings.count
      // file link: StatusTile's detail (LinkedText)
      return "\(count) shortcut\(count == 1 ? "" : "s") in config.json"
    }
    return parts.joined(separator: " · ")
  }
}

private enum TileState {
  /// `live`: something is running right now (automations).
  case good, attention, neutral, live

  var color: Color {
    switch self {
    case .good: return Theme.positive
    case .attention: return Theme.caution
    case .neutral: return Theme.neutral
    case .live: return Theme.critical
    }
  }
}

private struct StatusTile<Action: View>: View {
  let title: String
  let symbol: String
  let tint: Color
  let value: String
  let state: TileState
  let detail: String
  @ViewBuilder var action: Action

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top) {
        IconTile(symbol: symbol, tint: tint, size: 28)
        Spacer()
        action
          .buttonStyle(.soft)
          .controlSize(.small)
      }
      .frame(height: 28)
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          Text(title).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
          StatusDot(color: state.color, size: 6)
        }
        Text(value).font(.system(size: 17, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
        LinkedText(detail).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .cardStyle(padding: 14)
  }
}

// MARK: - Activity

private struct ActivityCard: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    let status = model.runtimeStatus
    VStack(alignment: .leading, spacing: 10) {
      SectionHeader("Activity", symbol: "clock")
      VStack(spacing: 0) {
        // config key: none, live activity rather than a setting
        SettingRow(
          title: status.lastAction ?? "Nothing yet",
          subtitle: status.lastAction == nil ? "Use a shortcut and it shows up here." : "Last action",
          symbol: "bolt.fill", tint: Theme.accent
        ) { EmptyView() }
        if let error = status.lastError {
          CardDivider(inset: 54)
          // config key: none, live activity rather than a setting
          SettingRow(
            title: error, subtitle: "Last problem", symbol: "exclamationmark.triangle.fill", tint: Theme.caution
          ) {
            EmptyView()
          }
        }
      }
      .cardStyle(padding: 0)
    }
  }
}

// MARK: - Tips

private struct QuickTips: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    let tips = self.tips
    if !tips.isEmpty {
      VStack(alignment: .leading, spacing: 10) {
        SectionHeader("Try These", symbol: "lightbulb")
        HStack(alignment: .top, spacing: 12) {
          ForEach(tips, id: \.title) { tip in
            VStack(alignment: .leading, spacing: 10) {
              tip.keys
                .frame(height: 28, alignment: .leading)
              Text(tip.title).font(.system(size: 13, weight: .semibold))
              Text(tip.detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .cardStyle(padding: 14)
          }
        }
      }
    }
  }

  private struct Tip {
    var title: String
    var detail: String
    var keys: AnyView
  }

  /// Up to three tips drawn from the user's own setup, each about a different feature: a window
  /// shortcut, clipboard history, a hotstring, then a second window tip or an automation.
  private var tips: [Tip] {
    let bindings = model.configuration.bindings.filter(\.enabled)
    var snapTip: Tip?
    if let snap = bindings.first(where: { WindowPresets.matching($0.action)?.group == .halves }) {
      snapTip = Tip(
        title: "Snap a window", detail: "\(BindingTitle.title(for: snap)) for the window in front.",
        keys: AnyView(KeyComboView(combo: snap.keys, modal: snap.modal)))
    }
    var windowTip: Tip?
    if let chain = bindings.first(where: { if case .chain = $0.action { return true } else { return false } }),
      case .chain(let steps) = chain.action
    {
      let names = steps.prefix(3).map(ActionDescriber.title).joined(separator: " → ")
      windowTip = Tip(
        title: "Cycle sizes", detail: "Press it again and again: \(names).",
        keys: AnyView(KeyComboView(combo: chain.keys, modal: chain.modal)))
    } else if let screen = bindings.first(where: { WindowPresets.matching($0.action)?.group == .screens }) {
      windowTip = Tip(
        title: "Switch displays", detail: "\(BindingTitle.title(for: screen)) — the window keeps its size.",
        keys: AnyView(KeyComboView(combo: screen.keys, modal: screen.modal)))
    }
    var clipboardTip: Tip?
    if model.configuration.clipboard.enabled, let shortcut = model.configuration.clipboard.shortcut {
      clipboardTip = Tip(
        title: "Paste from history", detail: "Anything you copied lately: type to search, then press Return.",
        keys: AnyView(KeyComboView(combo: shortcut)))
    }
    var hotstringTip: Tip?
    if let hotstring = model.configuration.hotstrings.first(where: { $0.enabled && !$0.trigger.isEmpty }) {
      hotstringTip = Tip(
        title: "Expand text",
        detail:
          "Type \(hotstring.trigger) anywhere to get “\(ActionDescriber.truncate(ActionDescriber.singleLine(hotstring.replacement), 22))”.",
        keys: AnyView(TriggerChip(trigger: hotstring.trigger)))
    }
    var automationTip: Tip?
    if let automation = model.automationBindings.first(where: { $0.enabled && !$0.keys.key.isEmpty }) {
      automationTip = Tip(
        title: "Start \(BindingTitle.title(for: automation))",
        detail: "Press it again to stop. The stop shortcut stops everything.",
        keys: AnyView(KeyComboView(combo: automation.keys, modal: automation.modal)))
    }
    var tips = [snapTip, clipboardTip, hotstringTip, windowTip, automationTip].compactMap { $0 }
    if tips.isEmpty, model.hyperKeyEnabled {
      tips.append(
        Tip(
          title: "Hold Caps Lock", detail: "It's ⌃⌥⇧⌘ now — a modifier no app uses, so ✦ shortcuts never clash.",
          keys: AnyView(
            HStack(spacing: 6) {
              Keycap(label: "⇪"); Image(systemName: "arrow.right").foregroundStyle(.tertiary);
              Keycap(label: "✦", isAccent: true)
            })))
    }
    return Array(tips.prefix(3))
  }
}

/// A hotstring trigger set in a monospaced chip, e.g. `;shrug`.
struct TriggerChip: View {
  let trigger: String
  var size: CGFloat = 12

  var body: some View {
    Text(trigger.isEmpty ? "—" : trigger)
      .font(.system(size: size, weight: .medium, design: .monospaced))
      .padding(.horizontal, 7)
      .padding(.vertical, 3)
      .background(SettingsPane.hotstrings.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(
          SettingsPane.hotstrings.tint.opacity(0.25), lineWidth: 0.6)
      )
      .foregroundStyle(SettingsPane.hotstrings.tint)
  }
}

// MARK: - Next steps

private struct NextSteps: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    let steps = self.steps
    if !steps.isEmpty {
      VStack(alignment: .leading, spacing: 10) {
        SectionHeader(title: "What's Next", symbol: "arrow.forward.circle") {
          // Get Started leaves the sidebar once setup is done; it's still here.
          Button {
            model.showGetStarted()
          } label: {
            Label("Get Started", systemImage: SettingsPane.getStarted.symbol)
          }
          .buttonStyle(.link)
          .font(.system(size: 12))
        }
        HStack(alignment: .top, spacing: 12) {
          ForEach(steps, id: \.title) { step in
            Button(action: step.run) {
              VStack(alignment: .leading, spacing: 8) {
                HStack {
                  IconTile(symbol: step.symbol, tint: step.tint, size: 26)
                  Spacer()
                  Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(
                    .tertiary)
                }
                Text(step.title).font(.system(size: 13, weight: .semibold))
                Text(step.detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
                  .fixedSize(horizontal: false, vertical: true)
              }
              .frame(maxWidth: .infinity, alignment: .topLeading)
              .cardStyle(padding: 14)
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
          }
        }
      }
    }
  }

  private struct Step {
    var title: String
    var detail: String
    var symbol: String
    var tint: Color
    var run: () -> Void
  }

  private var steps: [Step] {
    var steps: [Step] = []
    if !model.hyperKeyEnabled {
      steps.append(
        Step(
          title: "Turn on the Hyper key", detail: "Caps Lock becomes ⌃⌥⇧⌘ — room for dozens of shortcuts.",
          symbol: "capslock.fill", tint: SettingsPane.keyboard.tint, run: { model.selectedPane = .keyboard }))
    }
    if let slate = model.slateConfigPath, model.configuration.bindings.isEmpty {
      // file link: none here, the whole tile is the button that imports it.
      steps.append(
        Step(
          title: "Import your Slate config", detail: "Bring the shortcuts in \(slate) into Slated, to edit here.",
          symbol: "square.and.arrow.down.on.square", tint: SettingsPane.slate.tint,
          run: { model.importSlateConfigFromUI() }))
    }
    if model.configuration.hotstrings.count < 3 {
      steps.append(
        Step(
          title: "Add a hotstring", detail: "Type a short trigger, get a whole sentence.", symbol: "text.badge.plus",
          tint: SettingsPane.hotstrings.tint,
          run: {
            model.selectedPane = .hotstrings
            model.addHotstring()
          }))
    }
    if !model.configuration.clipboard.enabled {
      steps.append(
        Step(
          title: "Turn on clipboard history", detail: "Paste anything you copied earlier, from one shortcut.",
          symbol: SettingsPane.clipboard.symbol, tint: SettingsPane.clipboard.tint,
          run: { model.selectedPane = .clipboard }))
    }
    if model.automationBindings.isEmpty {
      steps.append(
        Step(
          title: "Try an auto-clicker", detail: "Let Slated click, hold or press keys for you, with a stop shortcut.",
          symbol: SettingsPane.automation.symbol, tint: SettingsPane.automation.tint,
          run: { model.selectedPane = .automation }))
    }
    if model.configuration.layouts.isEmpty {
      steps.append(
        Step(
          title: "Create a layout", detail: "Arrange all your apps for a task with one shortcut.",
          symbol: "rectangle.3.group",
          tint: SettingsPane.layouts.tint, run: { model.selectedPane = .layouts }))
    }
    if !model.configuration.general.launchAtLogin {
      steps.append(
        Step(
          title: "Launch at login", detail: "Have your shortcuts ready every time you log in.", symbol: "power",
          tint: SettingsPane.general.tint, run: { model.selectedPane = .general }))
    }
    if steps.count < 3 {
      steps.append(
        Step(
          title: "Fine-tune a shortcut", detail: "Every window shortcut has a live preview of where it lands.",
          symbol: "macwindow.on.rectangle", tint: SettingsPane.windows.tint, run: { model.selectedPane = .windows }))
    }
    return Array(steps.prefix(3))
  }
}
