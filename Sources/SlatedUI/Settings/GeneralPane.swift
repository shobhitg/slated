import SlatedCore
import SwiftUI

/// Startup, feedback, window behavior and where the configuration lives.
struct GeneralPane: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    @Bindable var model = model
    PaneScroll {
      PaneHeader(pane: .general, subtitle: "Startup, feedback and where your settings live.")
      SettingsCard(title: "Startup", symbol: "power") {
        ToggleRow(
          title: "Launch at login",
          subtitle: "Start Slated in the menu bar when you log in, so your shortcuts are always ready.",
          symbol: "power", tint: Color(hex: 0x30B85A),
          isOn: Binding(get: { model.configuration.general.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
      }
      SettingsCard(title: "Feedback", symbol: "sparkle") {
        HStack(spacing: 16) {
          VStack(alignment: .leading, spacing: 3) {
            Text("Show what just happened").font(.system(size: 13, weight: .medium))
            Text("A small HUD names the action each time a shortcut runs — handy while you learn your bindings.")
              .font(.system(size: 11.5))
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          Spacer(minLength: 12)
          HUDPreview(isOn: model.configuration.general.showActionHUD)
          Toggle("Show action HUD", isOn: $model.configuration.general.showActionHUD)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        .padding(16)
      }
      WindowBehaviorCard()
      SettingsCard(title: "Configuration File", symbol: "doc.badge.gearshape") {
        FactRow(label: "Location", value: displayPath(model.services.configurationFileURL.path), monospaced: true)
        CardDivider()
        HStack(spacing: 8) {
          SaveStatusLabel()
          Spacer()
          Button("Reveal in Finder") { model.revealConfigurationFile() }
            .buttonStyle(.soft)
          Button {
            model.reload()
          } label: {
            Label("Reload", systemImage: "arrow.clockwise")
          }
          .buttonStyle(.soft)
        }
        .controlSize(.small)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
      }
    }
  }

  private func displayPath(_ path: String) -> String {
    let home = NSHomeDirectory()
    return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
  }
}

/// A miniature of the action HUD, so the setting explains itself.
private struct HUDPreview: View {
  let isOn: Bool

  var body: some View {
    HStack(spacing: 6) {
      RegionGlyph(region: CGRect(x: 0, y: 0, width: 0.5, height: 1), width: 20, height: 13)
      Text("Left Half").font(.system(size: 11, weight: .semibold))
    }
    .foregroundStyle(.white)
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .background(Color.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.12)))
    .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
    .opacity(isOn ? 1 : 0.35)
    .scaleEffect(isOn ? 1 : 0.94)
    .animation(Theme.spring, value: isOn)
    .accessibilityHidden(true)
  }
}

/// The few Slate `config` values people actually tune, as friendly controls.
private struct WindowBehaviorCard: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    SettingsCard(
      title: "Window Behavior", symbol: "macwindow",
      footer: "These are Slate's own settings; a Slate file can override them."
    ) {
      ToggleRow(
        title: "Number displays from left to right",
        subtitle: "Display 1 is the leftmost. Turn off to use macOS's order, with the main display first.",
        symbol: "rectangle.split.3x1", tint: Color(hex: 0x2F7BF5), isOn: bool("orderScreensLeftToRight", default: true))
      CardDivider(inset: 54)
      SettingRow(
        title: "Repeat while held",
        subtitle: "How long to hold a shortcut before it repeats, for operations that repeat.",
        symbol: "repeat", tint: Color(hex: 0x7A5AF8)
      ) {
        Picker("Repeat delay", selection: number("secondsBeforeRepeat", default: 0.4)) {
          Text("Short").tag(0.25)
          Text("Medium").tag(0.4)
          Text("Long").tag(0.7)
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .fixedSize()
      }
      CardDivider(inset: 54)
      SettingRow(
        title: "Undo history", subtitle: "How many window moves Undo can step back through.",
        symbol: "arrow.uturn.backward",
        tint: Color(hex: 0x14A89A)
      ) {
        let value = number("undoMaxStackSize", default: 10)
        Stepper("\(Int(value.wrappedValue)) moves", value: value, in: 1...50)
          .font(.system(size: 12.5).monospacedDigit())
          .fixedSize()
      }
    }
  }

  private func bool(_ key: String, default value: Bool) -> Binding<Bool> {
    Binding(
      get: { model.configuration.settings.bool(key, default: value) },
      set: { model.configuration.settings[key] = .bool($0) })
  }

  private func number(_ key: String, default value: Double) -> Binding<Double> {
    Binding(
      get: { model.configuration.settings.double(key, default: value) },
      set: { model.configuration.settings[key] = .number($0) })
  }
}

/// "All changes saved" in words, for the configuration card.
struct SaveStatusLabel: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    let (text, symbol, color): (String, String, Color) = {
      switch model.saveState {
      case .saved: return ("All changes saved", "checkmark.circle.fill", Theme.positive)
      case .pending: return ("Saving…", "arrow.triangle.2.circlepath", .secondary)
      case .partiallySaved(let count):
        return (
          "\(count) item\(count == 1 ? "" : "s") not saved — fix the errors shown", "exclamationmark.triangle.fill",
          Theme.caution
        )
      case .failed(let message): return ("Couldn't save: \(message)", "xmark.octagon.fill", Theme.critical)
      case .blocked:
        return ("Saving paused until config.json can be read", "exclamationmark.triangle.fill", Theme.caution)
      }
    }()
    Label {
      Text(text).lineLimit(2)
    } icon: {
      Image(systemName: symbol).foregroundStyle(color)
    }
    .font(.system(size: 12))
    .foregroundStyle(.secondary)
  }
}
