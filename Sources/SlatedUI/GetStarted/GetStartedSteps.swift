import SlatedCore
import SwiftUI

// MARK: - Welcome

struct WelcomeStep: View {
  var body: some View {
    VStack(spacing: 26) {
      SlatedMark(size: 92, glow: true)
        .padding(.top, 8)
      StepTitle(
        title: "Welcome to Slated",
        subtitle: "Keyboard-first window management, a Hyper key and text expansion. A few quick steps and you're set.")
      HStack(alignment: .top, spacing: 12) {
        FeatureCard(
          symbol: "macwindow.on.rectangle", tint: SettingsPane.windows.tint, title: "Windows",
          detail: "Snap, resize and throw windows between displays."
        ) {
          KeyComboView(combo: KeyCombo(key: "left", modifiers: .hyper), size: .small)
        }
        FeatureCard(
          symbol: "capslock.fill", tint: SettingsPane.keyboard.tint, title: "Hyper Key",
          detail: "Caps Lock becomes ⌃⌥⇧⌘ — a modifier just for you."
        ) {
          HStack(spacing: 4) {
            Keycap(label: "⇪", size: .small)
            Image(systemName: "arrow.right").font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary)
            Keycap(label: "✦", size: .small, isAccent: true)
          }
        }
        FeatureCard(
          symbol: "text.insert", tint: SettingsPane.hotstrings.tint, title: "Hotstrings",
          detail: "Type a short trigger, get a whole sentence."
        ) {
          TriggerChip(trigger: ";shrug", size: 10.5)
        }
      }
      .fixedSize(horizontal: false, vertical: true)
    }
  }
}

private struct FeatureCard<Accessory: View>: View {
  let symbol: String
  let tint: Color
  let title: String
  let detail: String
  @ViewBuilder var accessory: Accessory

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        IconTile(symbol: symbol, tint: tint, size: 30)
        Spacer()
        accessory
      }
      Text(title).font(.system(size: 13.5, weight: .semibold))
      Text(detail)
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .cardStyle(padding: 14)
  }
}

// MARK: - Accessibility

struct AccessibilityStep: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    let granted = model.runtimeStatus.accessibilityGranted
    VStack(spacing: 24) {
      PermissionIllustration(granted: granted)
      StepTitle(
        title: granted ? "You're all set to move windows" : "Allow Slated to move your windows",
        subtitle:
          "macOS asks before any app can move windows or type for you. Slated uses this access only to arrange windows and insert your hotstrings — it never records or sends what you type."
      )
      VStack(spacing: 12) {
        if granted {
          Label("Accessibility access is on", systemImage: "checkmark.circle.fill")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.positive)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Theme.positive.opacity(0.1), in: Capsule())
            .transition(.scale.combined(with: .opacity))
        } else {
          Button {
            model.requestAccessibility()
          } label: {
            Label("Grant Access", systemImage: "hand.raised.fill")
          }
          .buttonStyle(.gradientLarge)
          HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text("Waiting for permission…").font(.system(size: 12)).foregroundStyle(.secondary)
            Text("·").foregroundStyle(.tertiary)
            Button("Open System Settings") { model.openAccessibilitySettings() }
              .buttonStyle(.link)
              .font(.system(size: 12))
          }
        }
      }
      .animation(Theme.spring, value: granted)
    }
  }
}

/// A miniature of the System Settings row the user is about to switch on.
private struct PermissionIllustration: View {
  let granted: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 6) {
        Image(systemName: "hand.raised.fill").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)
          .frame(width: 18, height: 18)
          .background(Color(hex: 0x2F7BF5), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        Text("Privacy & Security › Accessibility").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 10)
      Rectangle().fill(Theme.hairline).frame(height: 0.5)
      HStack(spacing: 10) {
        SlatedMark(size: 26)
        Text("Slated").font(.system(size: 13, weight: .medium))
        Spacer()
        Capsule()
          .fill(granted ? AnyShapeStyle(Theme.accentGradientHorizontal) : AnyShapeStyle(Color.primary.opacity(0.12)))
          .frame(width: 38, height: 22)
          .overlay(alignment: granted ? .trailing : .leading) {
            Circle().fill(.white).shadow(color: .black.opacity(0.2), radius: 1.5, y: 1).padding(2)
          }
          .animation(Theme.spring, value: granted)
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 12)
    }
    .frame(width: 320)
    .cardStyle(padding: 0)
    .overlay(alignment: .topTrailing) {
      if granted {
        Image(systemName: "checkmark.circle.fill")
          .font(.system(size: 24))
          .foregroundStyle(.white, Theme.positive)
          .offset(x: 10, y: -10)
          .transition(.scale.combined(with: .opacity))
      }
    }
    .animation(Theme.spring, value: granted)
  }
}

// MARK: - Hyper key

struct HyperKeyStep: View {
  @Environment(AppModel.self) private var model

  /// Points out when the user's own shortcuts already use ⌃⌥⇧⌘, so the choice is obvious.
  private var hyperSubtitle: String {
    let total = model.configuration.bindings.filter { $0.keys.modifiers.isSuperset(of: .hyper) }.count
    guard total > 0, !model.hyperKeyEnabled else { return "You can change this any time under Keyboard." }
    return "\(total) of your shortcuts use ⌃⌥⇧⌘. Turn this on to press them with Caps Lock. "
      + "(If Karabiner-Elements does this today, turn its Caps Lock rule off.)"
  }

  var body: some View {
    VStack(spacing: 24) {
      HyperIllustration(modifiers: model.configuration.keyboard.hyperModifiers, isOn: model.hyperKeyEnabled)
        .padding(.vertical, 16)
        .padding(.horizontal, 22)
        .background(Theme.cardBackground.opacity(0.7), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.cardStroke))
      StepTitle(
        title: "Turn Caps Lock into a Hyper key",
        subtitle:
          "Hold Caps Lock and it presses ⌃⌥⇧⌘ at once — a combination no app uses, so shortcuts like ✦← never clash with anything."
      )
      VStack(spacing: 0) {
        ToggleRow(
          title: "Use Caps Lock as Hyper", subtitle: hyperSubtitle,
          symbol: "capslock.fill", tint: SettingsPane.keyboard.tint,
          isOn: Binding(get: { model.hyperKeyEnabled }, set: { model.hyperKeyEnabled = $0 }))
        CardDivider(inset: 54)
        ToggleRow(
          title: "Tap alone for Escape", subtitle: "A quick tap sends Escape; holding it is Hyper.", symbol: "escape",
          tint: Color(hex: 0x14A89A),
          isOn: Binding(
            get: { model.configuration.keyboard.capsLockAlone == .escape },
            set: { model.configuration.keyboard.capsLockAlone = $0 ? .escape : .nothing })
        )
        .disabled(!model.hyperKeyEnabled)
        .opacity(model.hyperKeyEnabled ? 1 : 0.5)
      }
      .frame(maxWidth: 460)
      .cardStyle(padding: 0)
      Label(
        "Using Karabiner-Elements for Caps Lock? Quit it first so the two don't conflict.", systemImage: "info.circle"
      )
      .font(.system(size: 11.5))
      .foregroundStyle(.secondary)
    }
  }
}

// MARK: - Slate config

/// What became of the user's Slate config: imported (a first run does that by itself), there to
/// import, or not there, when the starter shortcuts are offered instead.
struct SlateConfigStep: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    let imported = model.lastSlateImport ?? model.slateImportNotice
    let found = model.slateConfigPath
    VStack(spacing: 22) {
      ZStack {
        IconTile(
          symbol: imported != nil
            ? "square.and.arrow.down.fill" : (found == nil ? "doc.badge.plus" : "doc.text.magnifyingglass"),
          tint: SettingsPane.slate.tint, size: 64)
        if imported != nil {
          Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 22))
            .foregroundStyle(.white, Theme.positive)
            .offset(x: 30, y: -30)
        }
      }
      .padding(.top, 6)
      if let imported {
        StepTitle(title: "Your Slate shortcuts are in Slated", subtitle: Self.importedText(imported))
        if !imported.notConverted.isEmpty {
          Label(
            "\(imported.notConverted.count) couldn't be converted: "
              + imported.notConverted.map(\.displayName).joined(separator: ", "),
            systemImage: "info.circle"
          )
          .font(.system(size: 11.5))
          .foregroundStyle(.secondary)
          .frame(maxWidth: 480)
        }
      } else if let found {
        StepTitle(
          title: "Your Slate config is here",
          subtitle: "Import \(found) to bring its shortcuts, layouts and settings into Slated, where you can "
            + "change them. Your file stays as it is; Slated doesn't run it.")
        Button("Import \(found)") { model.importSlateConfigFromUI() }
          .buttonStyle(.gradient)
      } else {
        StepTitle(
          title: "Start with a few great shortcuts",
          subtitle:
            "No ~/.slate or ~/.slate.js here — no problem. Add a starter set now and make it yours under Windows."
        )
      }
      // The starter set when there's nothing of the user's to bring over (or what came over has no
      // shortcuts); a Slate config waiting to be imported comes first.
      if imported == nil ? found == nil : model.configuration.bindings.isEmpty {
        StarterShortcutsCard()
      }
    }
  }

  static func importedText(_ report: SlateImportReport) -> String {
    let added =
      report.added > 0
      ? "Slated imported \(report.added) shortcut\(report.added == 1 ? "" : "s") from \(report.fileNames)."
      : "The shortcuts in \(report.fileNames) were already in Slated."
    return added + " Change them under Windows; Slated doesn't read \(report.fileNames) any more."
  }
}

/// Offers the starter Hyper shortcuts (halves, maximize, center, next display, undo).
private struct StarterShortcutsCard: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    let starter = WindowPresets.starterBindings
    let added = starter.allSatisfy { candidate in model.configuration.bindings.contains { $0.keys == candidate.keys } }
    HStack(spacing: 14) {
      VStack(alignment: .leading, spacing: 8) {
        Text(added ? "Starter shortcuts added" : "Add starter shortcuts").font(.system(size: 13, weight: .semibold))
        HStack(spacing: 6) {
          ForEach(Array(starter.prefix(5).enumerated()), id: \.offset) { _, binding in
            KeyComboView(combo: binding.keys, size: .small)
          }
          Text("+\(max(0, starter.count - 5))").font(.system(size: 11)).foregroundStyle(.tertiary)
        }
      }
      Spacer()
      if added {
        Image(systemName: "checkmark.circle.fill").font(.system(size: 22)).foregroundStyle(Theme.positive)
          .transition(.scale.combined(with: .opacity))
      } else {
        Button("Add \(starter.count)") {
          withAnimation(Theme.spring) { model.addStarterBindings() }
        }
        .buttonStyle(.gradient)
      }
    }
    .frame(maxWidth: 480)
    .cardStyle(padding: 14)
    .animation(Theme.spring, value: added)
  }
}

// MARK: - Done

struct DoneStep: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    VStack(spacing: 24) {
      ZStack {
        Circle()
          .fill(
            RadialGradient(
              colors: [Theme.accent.opacity(0.3), .clear], center: .center, startRadius: 10, endRadius: 80)
          )
          .frame(width: 160, height: 160)
        Circle()
          .fill(Theme.accentGradient)
          .frame(width: 76, height: 76)
          .overlay(Circle().strokeBorder(.white.opacity(0.3), lineWidth: 1))
          .shadow(color: Theme.accent.opacity(0.45), radius: 16, y: 6)
        Image(systemName: "checkmark")
          .font(.system(size: 32, weight: .bold))
          .foregroundStyle(.white)
        Image(systemName: "sparkle").font(.system(size: 16)).foregroundStyle(Theme.accentStops[2]).offset(x: 52, y: -38)
        Image(systemName: "sparkle").font(.system(size: 10)).foregroundStyle(Theme.accentStops[0]).offset(
          x: -54, y: -22)
        Image(systemName: "sparkle").font(.system(size: 12)).foregroundStyle(Theme.accentStops[1]).offset(x: -40, y: 44)
      }
      .frame(height: 130)
      StepTitle(
        title: "You're all set",
        subtitle:
          "Close this window and Slated keeps working in the background. Click Slated in the Dock any time to come back here."
      )
      VStack(spacing: 0) {
        checklistRow(
          "Accessibility access", done: model.runtimeStatus.accessibilityGranted,
          detail: model.runtimeStatus.accessibilityGranted ? "Allowed" : "Not yet")
        CardDivider(inset: 44)
        checklistRow("Hyper key", done: model.hyperKeyEnabled, detail: model.hyperKeyEnabled ? "Caps Lock is ✦" : "Off")
        CardDivider(inset: 44)
        checklistRow("Shortcuts", done: totalShortcuts > 0, detail: "\(totalShortcuts) ready")
      }
      .frame(maxWidth: 420)
      .cardStyle(padding: 0)
      if let tip = tipBinding {
        HStack(spacing: 8) {
          Text("Try it now:").font(.system(size: 12.5)).foregroundStyle(.secondary)
          KeyComboView(combo: tip.keys, modal: tip.modal, size: .small)
          Text(tip.title.lowercased()).font(.system(size: 12.5)).foregroundStyle(.secondary)
        }
      }
    }
  }

  private var totalShortcuts: Int { model.configuration.bindings.filter(\.enabled).count }

  private var tipBinding: (keys: KeyCombo, modal: ModalKey?, title: String)? {
    if let binding = model.configuration.bindings.first(where: {
      $0.enabled && WindowPresets.matching($0.action)?.group == .halves
    }) {
      return (binding.keys, binding.modal, "to snap this window to the \(BindingTitle.title(for: binding))")
    }
    if let binding = model.configuration.bindings.first(where: {
      $0.enabled && WindowPresets.matching($0.action) != nil
    }) {
      return (binding.keys, binding.modal, "for \(ActionDescriber.title(binding.action))")
    }
    return nil
  }

  private func checklistRow(_ title: String, done: Bool, detail: String) -> some View {
    HStack(spacing: 12) {
      Image(systemName: done ? "checkmark.circle.fill" : "circle.dashed")
        .font(.system(size: 17))
        .foregroundStyle(done ? Theme.positive : Theme.caution)
      Text(title).font(.system(size: 13, weight: .medium))
      Spacer()
      Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 11)
  }
}
