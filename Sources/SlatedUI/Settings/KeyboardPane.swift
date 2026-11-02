import SlatedCore
import SwiftUI

/// The Karabiner-Elements part: Caps Lock as a Hyper key, and key repeat.
struct KeyboardPane: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    @Bindable var model = model
    PaneScroll {
      PaneHeader(
        pane: .keyboard,
        subtitle: "Turn Caps Lock into a Hyper key, and make held keys repeat as fast as you like — no driver needed.")
      HyperCard()
      SettingsCard(title: "Options", symbol: "slider.horizontal.3") {
        ToggleRow(
          title: "Tap Caps Lock alone for Escape",
          subtitle: "A quick tap sends Escape; holding it is still Hyper. Handy in Vim and for closing dialogs.",
          symbol: "escape", tint: Color(hex: 0x14A89A), isOn: escapeBinding, configKey: ConfigKeys.capsLockAlone)
        CardDivider(inset: 54)
        SettingRow(
          title: "Hyper key sends", subtitle: modifierExplanation, symbol: "command", tint: SettingsPane.keyboard.tint,
          configKey: ConfigKeys.hyperModifiers
        ) {
          FittingPicker("Hyper key sends", selection: $model.configuration.keyboard.hyperModifiers) {
            Text("Hyper ⌃⌥⇧⌘").tag(Modifiers.hyper)
            Text("Meh ⌃⌥⇧").tag(Modifiers.meh)
          }
        }
      }
      .disabled(!model.hyperKeyEnabled)
      .opacity(model.hyperKeyEnabled ? 1 : 0.55)
      KeyRepeatCard()
      SettingsCard(title: "Good to Know", symbol: "lightbulb") {
        // config key: none, a fact rather than a setting
        SettingRow(
          title: "Secure Input pauses the Hyper key",
          subtitle:
            "While a password field has focus, macOS lets no app remap keys. Caps Lock acts normally until you leave the field.",
          symbol: "lock.shield.fill", tint: Color(hex: 0x2F7BF5)
        ) { EmptyView() }
        CardDivider(inset: 54)
        // config key: none, a fact rather than a setting
        SettingRow(
          title: "Using Karabiner-Elements?",
          subtitle: "Quit it, or remove its Caps Lock rule, so the two apps don't fight over the key.",
          symbol: "exclamationmark.triangle.fill", tint: Theme.caution
        ) { EmptyView() }
        CardDivider(inset: 54)
        // config key: none, a fact rather than a setting
        SettingRow(
          title: "Typing in capitals",
          subtitle: "Caps Lock no longer toggles capitals while it's the Hyper key. Hold Shift instead.",
          symbol: "textformat.size.larger", tint: Color(hex: 0x8A8A93)
        ) { EmptyView() }
      }
    }
  }

  private var escapeBinding: Binding<Bool> {
    Binding(
      get: { model.configuration.keyboard.capsLockAlone == .escape },
      set: { model.configuration.keyboard.capsLockAlone = $0 ? .escape : .nothing })
  }

  private var modifierExplanation: String {
    model.configuration.keyboard.hyperModifiers == .meh
      ? "Meh leaves out ⌘, so ✦ shortcuts can't collide with apps that watch ⌘."
      : "All four modifiers: no app uses this combination, so every ✦ shortcut is yours."
  }
}

/// The hero: the illustration, the explanation and the main switch.
private struct HyperCard: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    let isOn = model.hyperKeyEnabled
    VStack(alignment: .leading, spacing: 18) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 6) {
          HStack(spacing: 8) {
            Text("Caps Lock as Hyper").font(.system(size: 16, weight: .semibold))
            StatusPill(text: statusText, color: statusColor)
          }
          if model.showsConfigKeys { ConfigKeyCaption(key: ConfigKeys.capsLock) }
          Text(
            "Hold Caps Lock and every key you press gets \(model.configuration.keyboard.hyperModifiers.symbols) — a combination no app uses, so shortcuts like ✦← are all yours."
          )
          .font(.system(size: 12.5))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 20)
        // config key: the card's (keyboard.capsLock)
        Toggle("Caps Lock as Hyper", isOn: Binding(get: { model.hyperKeyEnabled }, set: { model.hyperKeyEnabled = $0 }))
          .labelsHidden()
          .toggleStyle(.switch)
      }
      .configKeyMenu(ConfigKeys.capsLock)
      HyperIllustration(modifiers: model.configuration.keyboard.hyperModifiers, isOn: isOn)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .background(PreviewStage())
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
    .cardStyle(padding: 18)
  }

  private var statusText: String {
    if !model.hyperKeyEnabled { return "Off" }
    if model.runtimeStatus.paused { return "Paused" }
    return model.runtimeStatus.hyperKeyActive ? "Active" : "Starting"
  }

  private var statusColor: Color {
    if !model.hyperKeyEnabled || model.runtimeStatus.paused { return Theme.neutral }
    return model.runtimeStatus.hyperKeyActive ? Theme.positive : Theme.caution
  }
}
