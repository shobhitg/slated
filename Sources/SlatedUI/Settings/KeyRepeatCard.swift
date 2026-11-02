import SlatedCore
import SwiftUI

/// Settings → Keyboard → Key Repeat: how long a held key waits before repeating, and how fast it
/// repeats, set from config.json on every computer that uses it. macOS's own sliders stop at 250 ms
/// and 30 per second; Slated goes as far as macOS does (1/60 s steps).
struct KeyRepeatCard: View {
  @Environment(AppModel.self) private var model
  @State private var tryText = ""

  var body: some View {
    SettingsCard(
      title: "Key Repeat", symbol: "repeat",
      footer: "Saved in config.json, so every Mac and Linux computer that uses it repeats keys the same way. "
        + "Turning this off leaves your Mac's setting as it is."
    ) {
      ToggleRow(
        title: "Set key repeat with Slated",
        subtitle: "Faster than System Settings allows. Starts from this Mac's current setting.",
        symbol: "repeat", tint: SettingsPane.keyboard.tint,
        isOn: Binding(get: { model.keyRepeatEnabled }, set: { model.keyRepeatEnabled = $0 }))
      if let setting = model.configuration.keyboard.keyRepeat {
        CardDivider(inset: 54)
        SliderRow(
          title: "Delay until repeat", subtitle: "How long you hold a key before it starts repeating.",
          symbol: "timer", tint: Color(hex: 0x2F7BF5), label: setting.delayLabel,
          slider: Binding(get: { Double(setting.delay) }, set: { setDelay(snapped: $0) }),
          range: Double(KeyRepeat.delayRange.lowerBound)...Double(KeyRepeat.delayRange.upperBound),
          ends: ("Short", "Long"),
          field: Binding(get: { setting.delay }, set: { model.configuration.keyboard.keyRepeat?.delay = $0 }))
        CardDivider(inset: 54)
        SliderRow(
          title: "Repeat rate", subtitle: "How fast it repeats after that.", symbol: "hare.fill",
          tint: Color(hex: 0x14A89A), label: setting.rateLabel,
          slider: Binding(get: { 1000 / setting.macEffectiveInterval }, set: { setRate(perSecond: $0) }),
          range: 2...60, ends: ("Slow", "Fast"),
          field: Binding(get: { setting.interval }, set: { model.configuration.keyboard.keyRepeat?.interval = $0 }))
        CardDivider(inset: 54)
        HStack(spacing: 10) {
          TextField("Try it here: hold down a key", text: $tryText)
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 260)
          Spacer(minLength: 8)
          Button("Use This Mac's Current Setting") { model.useCurrentKeyRepeat() }
            .buttonStyle(.soft)
        }
        .controlSize(.small)
        .padding(.leading, 54)
        .padding(.trailing, 16)
        .padding(.vertical, 10)
        CardDivider()
        KeyRepeatStatusLine()
          .padding(.horizontal, 16)
          .padding(.vertical, 10)
      }
    }
  }

  /// The slider moves in the Mac's 1/60 s steps; the number field takes any whole number.
  private func setDelay(snapped value: Double) {
    let ticks = MacKeyRepeatTicks.ticks(milliseconds: Int(value.rounded()))
    model.configuration.keyboard.keyRepeat?.delay = MacKeyRepeatTicks.milliseconds(ticks: ticks)
  }

  /// Repeats per second, to the nearest rate the Mac can do (60, 30, 20, 15… per second).
  private func setRate(perSecond value: Double) {
    let ticks = max(1, Int((Double(MacKeyRepeatTicks.perSecond) / max(value, 1)).rounded()))
    model.configuration.keyboard.keyRepeat?.interval = MacKeyRepeatTicks.milliseconds(ticks: ticks)
  }
}

/// A setting with a slider, its value in words, and a number field (milliseconds).
private struct SliderRow: View {
  let title: String
  let subtitle: String
  let symbol: String
  let tint: Color
  let label: String
  @Binding var slider: Double
  let range: ClosedRange<Double>
  let ends: (String, String)
  @Binding var field: Int

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      SettingRow(title: title, subtitle: subtitle, symbol: symbol, tint: tint) {
        Text(label)
          .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
          .foregroundStyle(tint)
      }
      .padding(.bottom, -8)
      HStack(spacing: 10) {
        Text(ends.0).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 34, alignment: .leading)
        Slider(value: $slider, in: range)
          .controlSize(.small)
          .accessibilityLabel(title)
          .accessibilityValue(label)
        Text(ends.1).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 30, alignment: .trailing)
        TextField(title, value: $field, format: .number)
          .textFieldStyle(.roundedBorder)
          .multilineTextAlignment(.trailing)
          .frame(width: 58)
          .controlSize(.small)
          .labelsHidden()
        Text("ms").font(.system(size: 11.5)).foregroundStyle(.secondary)
      }
      .padding(.leading, 54)
      .padding(.trailing, 16)
      .padding(.bottom, 12)
    }
  }
}

/// "Applied", or that macOS uses the change after logging out and back in.
struct KeyRepeatStatusLine: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    switch model.keyRepeatStatus {
    case .off:
      EmptyView()
    case .saving:
      label("Saving…", symbol: "clock", color: .secondary)
    case .applied:
      label("Applied: your keyboard repeats this way now.", symbol: "checkmark.circle.fill", color: Theme.positive)
    case .afterLogout:
      Notice(
        style: .info, title: KeyRepeatText.logoutTitle, message: KeyRepeatText.logoutMessage,
        symbol: "person.crop.circle.badge.clock")
    case .failed(let message):
      Notice(
        style: .warning, title: "Couldn't change key repeat",
        message: "\(message). Your Mac keeps its current setting; try again, or set it in System Settings → Keyboard.")
    }
  }

  private func label(_ text: String, symbol: String, color: Color) -> some View {
    Label(text, systemImage: symbol)
      .font(.system(size: 12))
      .foregroundStyle(color)
  }
}

/// The log-out notice's words, shared by Settings and Overview.
enum KeyRepeatText {
  static let logoutTitle = "Saved. macOS uses the new key repeat after you log out and back in."
  static let logoutMessage =
    "Your setting is safe in config.json. macOS only reads it at login, so log out (or restart) when it suits you."
}
