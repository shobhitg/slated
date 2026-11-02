import SlatedCore
import SwiftUI

/// Startup, feedback, window behavior and where the configuration lives.
struct GeneralPane: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    @Bindable var model = model
    PaneScroll {
      PaneHeader(
        pane: .general,
        subtitle: "These settings are in ~/.config/slated/settings.json; shortcuts, hotstrings and the Hyper key "
          + "are in config.json beside it.")
      SettingsCard(title: "Startup and Menu Bar", symbol: "power") {
        ToggleRow(
          title: "Launch at login",
          subtitle: "Start Slated in the background when you log in, so your shortcuts are always ready.",
          symbol: "power", tint: Color(hex: 0x30B85A),
          isOn: Binding(get: { model.configuration.general.launchAtLogin }, set: { model.setLaunchAtLogin($0) }),
          configKey: ConfigKeys.launchAtLogin)
        CardDivider(inset: 54)
        ToggleRow(
          title: "Show Slated in the menu bar",
          subtitle: "Click the icon to open Slated, right-click it for a short menu. Without it, the Dock icon "
            + "opens Slated.",
          symbol: "menubar.rectangle", tint: Color(hex: 0x2F7BF5), isOn: $model.configuration.general.showStatusIcon,
          configKey: ConfigKeys.showStatusIcon)
      }
      if model.showsMenuBarNotice {
        MenuBarNoticeCard()
      }
      SettingsCard(title: "Feedback", symbol: "sparkle") {
        HStack(spacing: 16) {
          VStack(alignment: .leading, spacing: 3) {
            Text("Show what just happened").font(.system(size: 13, weight: .medium))
            if model.showsConfigKeys { ConfigKeyCaption(text: ConfigKeys.showActionHUD.display) }
            Text(
              "Names the action each time a shortcut runs — in the notch island, or a small HUD when the island is "
                + "off. Handy while you learn your bindings."
            )
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          }
          Spacer(minLength: 12)
          HUDPreview(isOn: model.configuration.general.showActionHUD)
          // config key: the row's (general.showActionHUD)
          Toggle("Show action HUD", isOn: $model.configuration.general.showActionHUD)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        .padding(16)
        .configKeyMenu(ConfigKeys.showActionHUD)
      }
      IslandCard()
      WindowBehaviorCard()
      SettingsCard(
        title: "Configuration Files", symbol: "doc.badge.gearshape",
        footer:
          "Shortcuts, hotstrings and the Hyper key are in \(displayPath(model.services.configurationFileURL.path)); "
          + "these settings are in \(model.services.settingsFileURL.lastPathComponent). Edit either by hand "
          + "and Slated picks up the change."
      ) {
        ToggleRow(
          title: "Show config keys",
          subtitle: "Each setting's key in config.json or settings.json, under its name. Right-click any setting to "
            + "copy its key or value, or to open its file.",
          symbol: "curlybraces", tint: Color(hex: 0x4F5BD5), isOn: $model.configuration.general.showConfigKeys,
          configKey: ConfigKeys.showConfigKeys)
        CardDivider(inset: 54)
        fileRow("Shortcuts", file: .config, url: model.services.configurationFileURL)
        CardDivider()
        fileRow("Settings", file: .settings, url: model.services.settingsFileURL)
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

  /// A file's path, with a button that opens it in your editor.
  private func fileRow(_ label: String, file: ConfigFile, url: URL) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Text(label).foregroundStyle(.secondary)
      Spacer(minLength: 8)
      Text(displayPath(url.path))
        .font(.system(size: 12, design: .monospaced))
        .textSelection(.enabled)
        .lineLimit(1)
        .truncationMode(.middle)
      Button("Open \(file.rawValue)") { model.openConfigFile(file) }
        .buttonStyle(.soft)
        .controlSize(.small)
        .fixedSize()
    }
    .font(.system(size: 13))
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
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

/// The notch island: what it shows and the Hyper cheat sheet.
private struct IslandCard: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    @Bindable var model = model
    let island = model.configuration.island
    SettingsCard(
      title: "Notch Island", symbol: "laptopcomputer",
      footer: "On displays without a notch, the island hangs from the top center of the screen."
    ) {
      ToggleRow(
        title: "Show the island",
        subtitle: "Running automations, the active modal key and quick feedback grow out of the notch. Hover over "
          + "a running automation to stop it.",
        symbol: "laptopcomputer", tint: Color(hex: 0x1C1C1E), isOn: $model.configuration.island.enabled,
        configKey: ConfigKeys.islandEnabled)
      CardDivider(inset: 54)
      ToggleRow(
        title: "Hold Caps Lock to see your shortcuts",
        subtitle: "Keep the Hyper key held for a moment to list every Hyper shortcut; after a modal key, its keys "
          + "appear the same way.",
        symbol: "keyboard", tint: Theme.accent, isOn: $model.configuration.island.cheatSheet,
        configKey: ConfigKeys.islandCheatSheet
      )
      .disabled(!island.enabled)
      CardDivider(inset: 54)
      SettingRow(
        title: "Cheat sheet delay",
        subtitle: "How long to hold before the shortcuts appear. Quick taps never show them.",
        symbol: "timer", tint: Color(hex: 0x2F7BF5), configKey: ConfigKeys.islandCheatSheetDelay
      ) {
        FittingPicker("Cheat sheet delay", selection: $model.configuration.island.cheatSheetDelay) {
          Text("Short").tag(0.3)
          Text("Medium").tag(0.5)
          Text("Long").tag(0.8)
          if ![0.3, 0.5, 0.8].contains(island.cheatSheetDelay) {
            Text(String(format: "%.2g s", island.cheatSheetDelay)).tag(island.cheatSheetDelay)
          }
        }
      }
      .disabled(!island.enabled || !island.cheatSheet)
      CardDivider(inset: 54)
      ToggleRow(
        title: "Explain shortcuts that can't run",
        subtitle: "When a shortcut has nothing to act on — no window to move, say — the island briefly says why.",
        symbol: "exclamationmark.triangle", tint: Theme.caution, isOn: $model.configuration.island.showFailures,
        configKey: ConfigKeys.islandShowFailures
      )
      .disabled(!island.enabled)
    }
  }
}

/// The few Slate `config` values people actually tune, as friendly controls.
private struct WindowBehaviorCard: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    SettingsCard(
      title: "Window Behavior", symbol: "macwindow",
      footer: "Slate's own settings, kept under windows in settings.json."
    ) {
      ToggleRow(
        title: "Number displays from left to right",
        subtitle: "Display 1 is the leftmost. Turn off to use macOS's order, with the main display first.",
        symbol: "rectangle.split.3x1", tint: Color(hex: 0x2F7BF5), isOn: bool("orderScreensLeftToRight", default: true),
        configKey: ConfigKeys.orderScreensLeftToRight)
      CardDivider(inset: 54)
      SettingRow(
        title: "Repeat while held",
        subtitle: "How long to hold a shortcut before it repeats, for operations that repeat.",
        symbol: "repeat", tint: Color(hex: 0x7A5AF8), configKey: ConfigKeys.secondsBeforeRepeat
      ) {
        FittingPicker("Repeat delay", selection: number("secondsBeforeRepeat", default: 0.4)) {
          Text("Short").tag(0.25)
          Text("Medium").tag(0.4)
          Text("Long").tag(0.7)
        }
      }
      CardDivider(inset: 54)
      SettingRow(
        title: "Undo history", subtitle: "How many window moves Undo can step back through.",
        symbol: "arrow.uturn.backward",
        tint: Color(hex: 0x14A89A), configKey: ConfigKeys.undoMaxStackSize
      ) {
        // What Undo keeps, as the engine reads the setting. Not `Int(_:)` of the raw number, which traps
        // on what a hand edit or an imported Slate config can put there: 1e20, Infinity, NaN.
        let moves = max(model.configuration.windows.undoMaxStackSize, 1)
        Stepper("\(moves) moves", value: undoMaxStackSize, in: 1...50)
          .font(.system(size: 12.5).monospacedDigit())
          .fixedSize()
      }
    }
  }

  /// The undo history stepper's value: a whole number in its range, whatever config.json holds.
  private var undoMaxStackSize: Binding<Double> {
    Binding(
      get: { Double(min(max(model.configuration.windows.undoMaxStackSize, 1), 50)) },
      set: { model.configuration.windows["undoMaxStackSize"] = .number($0) })
  }

  private func bool(_ key: String, default value: Bool) -> Binding<Bool> {
    Binding(
      get: { model.configuration.windows.bool(key, default: value) },
      set: { model.configuration.windows[key] = .bool($0) })
  }

  private func number(_ key: String, default value: Double) -> Binding<Double> {
    Binding(
      get: { model.configuration.windows.double(key, default: value) },
      set: { model.configuration.windows[key] = .number($0) })
  }
}
