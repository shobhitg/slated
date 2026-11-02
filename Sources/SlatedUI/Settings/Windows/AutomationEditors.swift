import SlatedCore
import SwiftUI

// Editors for the automation actions (click, press, hold, repeat, wait): drawn mouse buttons, key
// pickers with common game keys and holdable modifiers, intervals with presets and a live rate,
// and plain-language explanations.

// MARK: - Tiles

/// A selectable tile with a drawing and a caption: mouse buttons, "Key", "What to repeat".
struct ChoiceTile<Glyph: View>: View {
  let title: String
  let selected: Bool
  var width: CGFloat = 74
  let action: () -> Void
  @ViewBuilder var glyph: Glyph
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      VStack(spacing: 6) {
        glyph.frame(height: 32)
        Text(title)
          .font(.system(size: 11, weight: selected ? .semibold : .medium))
          .foregroundStyle(selected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.secondary))
          .lineLimit(1)
      }
      .frame(width: width, height: 68)
      .background(
        selected ? Theme.selection : (hovering ? Theme.well.opacity(1.6) : Theme.well),
        in: RoundedRectangle(cornerRadius: 11, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 11, style: .continuous)
          .strokeBorder(
            selected ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.wellStroke),
            lineWidth: selected ? 1.4 : 0.8)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .accessibilityLabel(title)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}

/// A rounded preset chip: "100 ms", "W".
struct PresetChip: View {
  let title: String
  let selected: Bool
  var monospaced = false
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Text(title)
        .font(.system(size: 11.5, weight: .medium, design: monospaced ? .monospaced : .default).monospacedDigit())
        .padding(.horizontal, 9)
        .frame(height: 24)
        .foregroundStyle(selected ? Color.white : Color.primary.opacity(0.8))
        .background {
          Capsule().fill(selected ? AnyShapeStyle(Theme.accentGradientHorizontal) : AnyShapeStyle(Theme.well))
        }
        .overlay(Capsule().strokeBorder(selected ? Color.white.opacity(0.2) : Theme.wellStroke, lineWidth: 0.7))
        .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}

// MARK: - Mouse buttons and keys

/// Left / Right / Middle, drawn as mice.
struct MouseButtonPicker: View {
  @Binding var button: MouseButton

  var body: some View {
    HStack(spacing: 8) {
      ForEach(MouseButton.allCases, id: \.self) { candidate in
        ChoiceTile(title: candidate.title, selected: button == candidate, action: { button = candidate }) {
          MouseGlyph(lit: candidate, height: 30)
        }
      }
    }
  }
}

/// What to click, press or hold: a mouse button, or a key (recorded, one of the common game keys,
/// or a modifier key, which the recorder can't capture on its own).
struct InputPicker: View {
  @Binding var input: SyntheticInput

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 8) {
        ForEach(MouseButton.allCases, id: \.self) { button in
          ChoiceTile(
            title: "\(button.title) Click", selected: input == .mouse(button), width: 80,
            action: { input = .mouse(button) }
          ) {
            MouseGlyph(lit: button, height: 30)
          }
        }
        ChoiceTile(title: "Key", selected: isKey, width: 80, action: { if !isKey { input = .key(KeyCombo(key: "w")) } })
        {
          Keycap(label: keyLabel, size: .regular)
        }
      }
      if case .key(let combo) = input {
        KeyChooser(combo: Binding(get: { combo }, set: { input = .key($0) }))
          .transition(.opacity.combined(with: .move(edge: .top)))
      }
    }
    .animation(Theme.snappy, value: isKey)
  }

  private var isKey: Bool {
    if case .key = input { return true }
    return false
  }

  private var keyLabel: String {
    if case .key(let combo) = input, !combo.key.isEmpty { return KeyNames.displayName(for: combo.key) }
    return "W"
  }
}

/// A key to send or hold: the recorder, a menu of modifier keys, and common game keys one click away.
struct KeyChooser: View {
  @Binding var combo: KeyCombo
  /// Offers Shift, Control… on their own (holdable); off for keystrokes, where they'd do nothing.
  var allowsModifierKeys = true

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        // config key: the caller's field
        ShortcutRecorder(combo: $combo, requiresModifier: false, allowsMouseButtons: false)
          .frame(maxWidth: 280)
        if allowsModifierKeys {
          Menu {
            ForEach(AutomationRecipes.modifierKeys, id: \.key) { modifier in
              Button(modifier.title) { combo = KeyCombo(key: modifier.key) }
            }
          } label: {
            Label("Modifier Key", systemImage: "shift")
          }
          .menuStyle(.borderlessButton)
          .fixedSize()
          .help("Shift, Control, Option or Command on their own, e.g. to hold Shift for sprinting.")
        }
      }
      HStack(spacing: 5) {
        Text("Common").font(.system(size: 11)).foregroundStyle(.tertiary).padding(.trailing, 2)
        ForEach(commonKeys, id: \.self) { key in
          Button {
            combo = KeyCombo(key: key)
          } label: {
            Keycap(label: KeyNames.displayName(for: key), size: .small, isAccent: combo == KeyCombo(key: key))
          }
          .buttonStyle(.plain)
          .help("Use \(KeyNames.displayName(for: key))")
        }
      }
    }
  }

  private var commonKeys: [String] {
    AutomationRecipes.commonGameKeys + (allowsModifierKeys ? ["shift", "ctrl"] : [])
  }
}

// MARK: - Interval

/// How often an auto-repeat runs: milliseconds with presets, and the rate it adds up to.
struct IntervalField: View {
  @Binding var interval: Double
  var jitter: Double = 0

  static let presets: [Double] = [0.05, 0.1, 0.25, 0.5, 1]

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 6) {
        // config key: the caller's field
        TextField(
          "100",
          value: Binding(
            get: { Int((interval * 1000).rounded()) }, set: { interval = max(0.01, Double($0) / 1000) }),
          format: .number
        )
        .textFieldStyle(.roundedBorder)
        .multilineTextAlignment(.trailing)
        .frame(width: 64)
        Text("ms").font(.system(size: 12)).foregroundStyle(.secondary).padding(.trailing, 6)
        ForEach(Self.presets, id: \.self) { preset in
          PresetChip(title: ActionDescriber.seconds(preset), selected: abs(interval - preset) < 0.0005) {
            withAnimation(Theme.snappy) { interval = preset }
          }
        }
      }
      HStack(alignment: .center, spacing: 14) {
        VStack(alignment: .leading, spacing: 0) {
          Text(rateNumber)
            .font(.system(size: 22, weight: .bold, design: .rounded).monospacedDigit())
            .foregroundStyle(Theme.accentGradientHorizontal)
            .contentTransition(.numericText())
          Text(rateUnit).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
        }
        .frame(width: 82, alignment: .leading)
        RateRuler(interval: interval, jitter: jitter)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 9)
      .wellStyle()
      .animation(Theme.snappy, value: interval)
      if interval < 0.03 {
        Label("Very fast. Some games ignore clicks faster than about 30 a second.", systemImage: "hare.fill")
          .font(.system(size: 11)).foregroundStyle(Theme.caution)
      }
    }
  }

  private var rateNumber: String {
    guard interval <= 1.0001 else { return ActionDescriber.seconds(interval) }
    let perSecond = 1 / interval
    return abs(perSecond - perSecond.rounded()) < 0.05
      ? "\(Int(perSecond.rounded()))" : String(format: "%.1f", perSecond)
  }

  private var rateUnit: String { interval <= 1.0001 ? "per second" : "between runs" }
}

/// Toggle or while held, as two cards that explain themselves.
struct RepeatModePicker: View {
  @Binding var mode: RepeatMode

  var body: some View {
    HStack(spacing: 8) {
      card(.toggle, symbol: "power", title: "Toggle")
      card(.whileHeld, symbol: "hand.point.down.fill", title: "While Held")
    }
  }

  private func card(_ value: RepeatMode, symbol: String, title: String) -> some View {
    let selected = mode == value
    return Button {
      withAnimation(Theme.snappy) { mode = value }
    } label: {
      HStack(alignment: .top, spacing: 9) {
        Image(systemName: symbol)
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
          .frame(width: 24, height: 24)
          .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
              .fill(selected ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.well))
          }
        VStack(alignment: .leading, spacing: 2) {
          Text(title).font(.system(size: 12.5, weight: .semibold))
          Text(AutomationDescriber.modeExplanation(value))
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 0)
      }
      .padding(10)
      .frame(maxWidth: 230, alignment: .leading)
      .background(selected ? Theme.selection : Color.clear, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 11, style: .continuous)
          .strokeBorder(
            selected ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.wellStroke),
            lineWidth: selected ? 1.4 : 0.8)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}

/// Runs until stopped, or stops by itself after N runs.
struct RepeatLimitField: View {
  @Binding var times: Int?
  var interval: Double = 0.1

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 10) {
        // config key: the caller's field
        FittingPicker("Stop", selection: limited) {
          Text("When stopped").tag(false)
          Text("After a number of runs").tag(true)
        }
        if let current = times {
          HStack(spacing: 6) {
            // config key: the caller's field
            TextField("50", value: Binding(get: { current }, set: { times = max(1, $0) }), format: .number)
              .textFieldStyle(.roundedBorder)
              .multilineTextAlignment(.trailing)
              .frame(width: 58)
            // config key: the caller's field
            Stepper("Runs", value: Binding(get: { current }, set: { times = max(1, $0) }), in: 1...100_000)
              .labelsHidden()
            Text("runs").font(.system(size: 12)).foregroundStyle(.secondary)
          }
          .transition(.opacity)
        }
      }
      if let times {
        Hint(
          "Stops by itself after \(times) run\(times == 1 ? "" : "s"), about \(ActionDescriber.seconds(Double(max(times - 1, 0)) * interval)) at this speed. Press the shortcut again to stop early."
        )
      }
    }
    .animation(Theme.snappy, value: times == nil)
  }

  private var limited: Binding<Bool> {
    Binding(get: { times != nil }, set: { times = $0 ? (times ?? 50) : nil })
  }
}

/// "Humanize timing": vary each interval by up to ±N% (0–50%), for games that ignore clockwork input.
struct JitterField: View {
  @Binding var jitter: Double

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 10) {
        // config key: the caller's field
        Toggle("Humanize timing", isOn: Binding(get: { jitter > 0 }, set: { jitter = $0 ? max(jitter, 0.15) : 0 }))
          .toggleStyle(.switch)
          .controlSize(.small)
          .font(.system(size: 12.5, weight: .medium))
        if jitter > 0 {
          // config key: the caller's field
          Slider(value: Binding(get: { jitter }, set: { jitter = max(0.05, ($0 * 20).rounded() / 20) }), in: 0.05...0.5)
            .frame(width: 150)
          Text(AutomationDescriber.jitter(jitter))
            .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
            .foregroundStyle(Theme.accent)
            .frame(width: 44, alignment: .leading)
        }
      }
      Hint(
        jitter > 0
          ? "Each interval varies by up to \(AutomationDescriber.jitter(jitter)), so it doesn't tick like clockwork."
          : "Off: perfectly even timing. Some games ignore input that's too regular; humanizing helps.")
    }
    .animation(Theme.snappy, value: jitter > 0)
  }
}

// MARK: - What to repeat

/// The action an auto-repeat runs: a click or a key inline, or anything else in a nested editor.
struct RepeatedActionEditor: View {
  @Binding var action: Action
  var depth: Int
  @State private var editing = false

  private enum Choice { case click, key, other }

  private var choice: Choice {
    switch action {
    case .click: return .click
    case .keystroke: return .key
    default: return .other
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 8) {
        ChoiceTile(
          title: "Click", selected: choice == .click,
          action: { if choice != .click { action = .click(.left, count: 1) } }
        ) {
          MouseGlyph(lit: clickButton, height: 30)
        }
        ChoiceTile(
          title: "Press a Key", selected: choice == .key, width: 86,
          action: { if choice != .key { action = .keystroke(KeyCombo(key: "e")) } }
        ) {
          Keycap(label: keyLabel, size: .regular)
        }
        ChoiceTile(title: "Something Else", selected: choice == .other, width: 96, action: { editing = true }) {
          Image(systemName: choice == .other ? ActionKind(action).symbol : "ellipsis.circle")
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(Theme.accentGradient)
        }
        .popover(isPresented: $editing, arrowEdge: .bottom) {
          ScrollView {
            ActionEditor(action: $action, depth: depth + 1, excluded: [.autoRepeat])
              .padding(18)
          }
          .frame(width: 500, height: 480)
        }
      }
      switch action {
      case .click(let button, let count):
        HStack(spacing: 14) {
          MouseButtonPicker(button: Binding(get: { button }, set: { action = .click($0, count: count) }))
          // config key: the caller's field
          FittingPicker(
            "Clicks", selection: Binding(get: { min(count, 2) }, set: { action = .click(button, count: $0) })
          ) {
            Text("Single").tag(1)
            Text("Double").tag(2)
          }
        }
      case .keystroke(let combo):
        KeyChooser(combo: Binding(get: { combo }, set: { action = .keystroke($0) }), allowsModifierKeys: false)
      default:
        HStack(spacing: 10) {
          ActionGlyph(action: action, width: 26, height: 18)
          VStack(alignment: .leading, spacing: 1) {
            Text(ActionDescriber.title(action)).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
            Text(ActionDescriber.detail(action)).font(.system(size: 10.5, design: .monospaced))
              .foregroundStyle(.secondary).lineLimit(1)
          }
          Spacer(minLength: 6)
          Button("Edit") { editing = true }.buttonStyle(.soft).controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .wellStyle()
      }
    }
  }

  private var clickButton: MouseButton {
    if case .click(let button, _) = action { return button }
    return .left
  }

  private var keyLabel: String {
    if case .keystroke(let combo) = action, !combo.key.isEmpty { return KeyNames.displayName(for: combo.key) }
    return "E"
  }
}

// MARK: - Durations

/// A wait in seconds, with presets.
struct DurationField: View {
  @Binding var seconds: Double

  static let presets: [Double] = [0.1, 0.25, 0.5, 1, 2, 5]

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        // config key: the caller's field
        TextField("0.5", value: $seconds, format: .number.precision(.fractionLength(0...3)))
          .textFieldStyle(.roundedBorder)
          .multilineTextAlignment(.trailing)
          .frame(width: 64)
          .onChange(of: seconds) { _, value in if value < 0 { seconds = 0 } }
        Text("seconds").font(.system(size: 12)).foregroundStyle(.secondary).padding(.trailing, 6)
        ForEach(Self.presets, id: \.self) { preset in
          PresetChip(title: ActionDescriber.seconds(preset), selected: abs(seconds - preset) < 0.0005) {
            seconds = preset
          }
        }
      }
      Hint("Waits only pause a sequence. Steps after the wait run when it's over; nothing is blocked meanwhile.")
    }
  }
}

/// Press down or release.
struct PressPhasePicker: View {
  @Binding var phase: PressPhase

  var body: some View {
    // config key: the caller's field
    FittingPicker("Press or release", selection: $phase) {
      Label("Press Down", systemImage: "arrow.down.to.line").tag(PressPhase.down)
      Label("Release", systemImage: "arrow.up.to.line").tag(PressPhase.up)
    }
  }
}

// MARK: - Explanations

/// The safety rails, in one line, for anything that holds or repeats: shown in automation editors.
struct AutomationSafetyNote: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    let settings = model.configuration.automation
    HStack(alignment: .center, spacing: 10) {
      Image(systemName: "shield.lefthalf.filled")
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(SettingsPane.automation.tint)
      FlowLayout(spacing: 10) {
        if let stop = settings.stopShortcut {
          HStack(spacing: 5) {
            KeyComboView(combo: stop, size: .small)
            Text("stops everything").foregroundStyle(.secondary)
          }
        } else {
          Text("No stop shortcut").fontWeight(.medium).foregroundStyle(Theme.caution)
        }
        if settings.stopOnAppSwitch {
          Label("Stops when you switch apps", systemImage: "arrow.left.arrow.right").foregroundStyle(.secondary)
        }
        if settings.maxRunMinutes > 0 {
          Label("Stops after \(AutomationLimits.timeLimitTitle(settings.maxRunMinutes))", systemImage: "timer")
            .foregroundStyle(.secondary)
        }
      }
      .font(.system(size: 11.5))
      .labelStyle(SmallIconLabelStyle())
      Spacer(minLength: 6)
      Button("Safety…") { model.selectedPane = .automation }
        .buttonStyle(.link)
        .font(.system(size: 11.5))
        .fixedSize()
        .help("Settings → Automation")
    }
    .lineLimit(1)
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(SettingsPane.automation.tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(
        SettingsPane.automation.tint.opacity(0.2), lineWidth: 0.6))
  }
}

/// A label with a small, tinted-down icon, for dense lines of facts.
struct SmallIconLabelStyle: LabelStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 4) {
      configuration.icon.font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.tertiary)
      configuration.title
    }
  }
}

/// What Stop Automations does, and the built-in shortcut that does the same.
struct StopAutomationsInfo: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let stop = model.configuration.automation.stopShortcut {
        HStack(spacing: 6) {
          Text("Slated's built-in stop shortcut does the same:").font(.system(size: 12)).foregroundStyle(.secondary)
          KeyComboView(combo: stop, size: .small)
        }
      }
      Button("Automation Settings…") { model.selectedPane = .automation }
        .buttonStyle(.link)
        .font(.system(size: 12))
    }
  }
}

/// What Clipboard History does, and the built-in shortcut.
struct ClipboardHistoryInfo: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if !model.configuration.clipboard.enabled {
        Notice(
          style: .warning, title: "Clipboard history is off",
          message: "Turn it on in Settings → Clipboard, or this shortcut has nothing to show.")
      } else if let shortcut = model.configuration.clipboard.shortcut {
        HStack(spacing: 6) {
          Text("The built-in shortcut opens it too:").font(.system(size: 12)).foregroundStyle(.secondary)
          KeyComboView(combo: shortcut, size: .small)
        }
      }
      Button("Clipboard Settings…") { model.selectedPane = .clipboard }
        .buttonStyle(.link)
        .font(.system(size: 12))
    }
  }
}
