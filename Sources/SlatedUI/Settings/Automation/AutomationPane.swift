import SlatedCore
import SwiftUI

/// Game-style automation (AutoHotkey's job): what it is and how it's kept safe, what's running now,
/// your automations, one-click recipes, and the safety settings.
struct AutomationPane: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    PaneScroll {
      PaneHeader(pane: .automation, subtitle: "Auto-clickers, held keys and macros for games and repetitive work.") {
        NewItemButton(title: "New Automation") { model.newAutomation() }
      }
      AutomationHero()
      Notice(
        style: .warning, title: "Check the game's rules first",
        message:
          "Many games accept automated input, but online games with anti-cheat may block it, and their terms of service can forbid it. Use automation where it's allowed: single-player and idle games, and your own work.",
        symbol: "exclamationmark.shield.fill")
      VStack(alignment: .leading, spacing: 10) {
        SectionHeader("Running Now", symbol: "dot.radiowaves.left.and.right")
        RunningAutomationsCard()
      }
      .animation(Theme.spring, value: model.activeAutomations.isEmpty)
      YourAutomations()
      RecipeGallery()
      SafetyCard()
    }
  }
}

// MARK: - Hero

private struct AutomationHero: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    HStack(alignment: .center, spacing: 20) {
      VStack(alignment: .leading, spacing: 8) {
        Text("On autopilot")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(Theme.accentGradientHorizontal)
          .textCase(.uppercase)
          .tracking(0.6)
        Text("Let Slated click and press for you")
          .font(.system(size: 22, weight: .bold))
          .tracking(-0.4)
        Text(
          "Auto-clickers, held keys and short macros. Each automation is a shortcut: press it to start, press it again to stop. Limit one to a game, and even a plain key like F works as its shortcut."
        )
        .font(.system(size: 12.5))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        FlowLayout(spacing: 6) {
          rails
        }
        .padding(.top, 4)
      }
      Spacer(minLength: 8)
      HeroArt()
        .frame(width: 176, height: 132)
    }
    .padding(22)
    .background {
      ZStack {
        Theme.cardBackground
        RadialGradient(
          colors: [SettingsPane.automation.tint.opacity(0.16), .clear], center: .topTrailing, startRadius: 10,
          endRadius: 380)
        RadialGradient(
          colors: [Theme.accentStops[1].opacity(0.10), .clear], center: .bottomLeading, startRadius: 10, endRadius: 300)
      }
      .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.cardStroke))
    .shadow(color: Theme.cardShadow, radius: 14, y: 4)
  }

  @ViewBuilder private var rails: some View {
    let settings = model.configuration.automation
    if let stop = settings.stopShortcut {
      RailChip(symbol: "stop.circle.fill", tint: Theme.critical) {
        KeyComboView(combo: stop, size: .small)
        Text("stops everything")
      }
    } else {
      RailChip(symbol: "exclamationmark.triangle.fill", tint: Theme.caution) { Text("No stop shortcut") }
    }
    RailChip(symbol: "arrow.left.arrow.right", tint: SettingsPane.automation.tint) {
      Text(settings.stopOnAppSwitch ? "Stops on app switch" : "Runs across apps")
    }
    RailChip(symbol: "timer", tint: Color(hex: 0x7A5AF8)) {
      Text(
        settings.maxRunMinutes > 0
          ? "Stops after \(AutomationLimits.timeLimitTitle(settings.maxRunMinutes))" : "No time limit")
    }
  }
}

/// A capsule with an icon and a short fact: one of the safety rails.
private struct RailChip<Content: View>: View {
  let symbol: String
  let tint: Color
  @ViewBuilder var content: Content

  var body: some View {
    HStack(spacing: 5) {
      Image(systemName: symbol).font(.system(size: 10, weight: .bold)).foregroundStyle(tint)
      content
    }
    .font(.system(size: 11.5, weight: .medium))
    .padding(.horizontal, 9)
    .frame(height: 26)
    .background(Theme.cardBackground.opacity(0.7), in: Capsule())
    .overlay(Capsule().strokeBorder(Theme.cardStroke))
  }
}

/// The hero's drawing: a mouse auto-clicking and a key held down, on a soft stage.
private struct HeroArt: View {
  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .fill(Theme.well)
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .fill(
          RadialGradient(
            colors: [SettingsPane.automation.tint.opacity(0.22), .clear], center: .center, startRadius: 4,
            endRadius: 100))
      MouseGlyph(lit: .left, height: 66)
        .overlay(alignment: .topLeading) {
          ClickRipples(towardsLeft: true, size: 30).offset(x: -24, y: -17)
        }
        .overlay(alignment: .bottomTrailing) {
          ArtBadge(text: "10/s", size: 10).offset(x: 18, y: 4)
        }
        .offset(x: -30, y: 4)
      Keycap(label: "W", size: .large, caption: "held", isPressed: true)
        .overlay(alignment: .topTrailing) { HoldBadge(size: 16).offset(x: 7, y: -6) }
        .offset(x: 44, y: 12)
    }
    .accessibilityHidden(true)
  }
}

// MARK: - Your automations

private struct YourAutomations: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    let bindings = model.automationBindings
    VStack(alignment: .leading, spacing: 10) {
      SectionHeader(title: "Your Automations", symbol: "square.stack.3d.up.fill") {
        if !bindings.isEmpty {
          Text("Saved with your shortcuts, also listed in Windows")
            .font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
      }
      if bindings.isEmpty {
        HStack(spacing: 12) {
          IconTile(symbol: "wand.and.stars", tint: SettingsPane.automation.tint, size: 30)
          VStack(alignment: .leading, spacing: 2) {
            Text("No automations yet").font(.system(size: 13, weight: .medium))
            Text("Add a recipe below, or build your own. Each one is a shortcut you can edit in Settings → Windows.")
              .font(.system(size: 11.5)).foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          Spacer(minLength: 8)
        }
        .padding(16)
        .cardStyle(padding: 0)
      } else {
        VStack(spacing: 0) {
          ForEach(bindings) { binding in
            if binding.id != bindings.first?.id { CardDivider(inset: 72) }
            AutomationBindingRow(binding: binding)
          }
        }
        .cardStyle(padding: 0)
      }
    }
  }
}

/// One automation binding: a small drawing, its name and what it does, where it works, its keys,
/// live state and an on/off switch.
struct AutomationBindingRow: View {
  let binding: HotkeyBinding
  @Environment(AppModel.self) private var model

  var body: some View {
    let state = model.state(for: binding)
    let running = !model.activeAutomations(for: binding).isEmpty
    HStack(spacing: 12) {
      AutomationThumbnail(action: binding.action)
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          Text(BindingTitle.title(for: binding)).font(.system(size: 13, weight: .semibold)).lineLimit(1)
          if running {
            HStack(spacing: 4) {
              LiveDot(size: 6)
              Text("Running").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.critical)
            }
          }
        }
        HStack(spacing: 5) {
          if let badge = state.rowBadge {
            Image(systemName: badge.symbol).font(.system(size: 9, weight: .bold)).foregroundStyle(badge.color)
            Text(badge.text).foregroundStyle(badge.color)
          } else {
            Text(AutomationDescriber.sentence(binding.action)).foregroundStyle(.secondary)
          }
        }
        .font(.system(size: 11.5))
        .lineLimit(1)
        if !binding.onlyInApps.isEmpty {
          HStack(spacing: 4) {
            Text("Only in").foregroundStyle(.tertiary)
            ForEach(binding.onlyInApps.prefix(3), id: \.self) { id in
              AppIconView(bundleID: id, size: 13)
              Text(model.appName(bundleID: id)).foregroundStyle(.secondary)
            }
          }
          .font(.system(size: 11))
          .lineLimit(1)
        }
      }
      Spacer(minLength: 8)
      if binding.keys.key.isEmpty {
        Text("No shortcut").font(.system(size: 11)).foregroundStyle(.tertiary)
      } else {
        KeyComboView(combo: binding.keys, modal: binding.modal, size: .small)
      }
      Toggle("Enabled", isOn: enabled)
        .labelsHidden()
        .toggleStyle(.switch)
        .controlSize(.small)
        .help(binding.enabled ? "Turn this automation off" : "Turn this automation on")
      Button {
        model.openInEditor(binding.id)
      } label: {
        Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
      }
      .buttonStyle(.borderless)
      .help("Edit in Settings → Windows")
      .accessibilityLabel("Edit \(BindingTitle.title(for: binding))")
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .opacity(binding.enabled ? 1 : 0.55)
    .contentShape(Rectangle())
    .contextMenu {
      Button("Edit…") { model.openInEditor(binding.id) }
      Button("Duplicate") {
        model.duplicateBinding(binding.id)
        model.selectedPane = .windows
      }
      Divider()
      Button("Delete", role: .destructive) { model.deleteBinding(binding.id) }
    }
  }

  private var enabled: Binding<Bool> {
    Binding(
      get: { binding.enabled },
      set: { value in
        guard let index = model.configuration.bindings.firstIndex(where: { $0.id == binding.id }) else { return }
        model.configuration.bindings[index].enabled = value
      })
  }
}

// MARK: - Safety settings

private struct SafetyCard: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    @Bindable var model = model
    let settings = model.configuration.automation
    SettingsCard(
      title: "Safety", symbol: "shield.lefthalf.filled",
      footer:
        "Slated never leaves a button or key held down: pausing Slated, sleep, locking the screen and quitting all let go of everything."
    ) {
      VStack(alignment: .leading, spacing: 0) {
        SettingRow(
          title: "Stop shortcut", subtitle: "Stops every automation and lets go of anything held, from any app.",
          symbol: "stop.circle.fill", tint: Theme.critical
        ) {
          OptionalShortcutRecorder(
            combo: $model.configuration.automation.stopShortcut, defaultCombo: AutomationSettings().stopShortcut)
        }
        let conflicts = model.otherUses(ofBuiltIn: .stopAutomations)
        if settings.stopShortcut == nil {
          Notice(
            style: .warning, title: "No stop shortcut",
            message: "Stop automations from the notch island or Overview, or by pressing each one's shortcut again."
          )
          .padding(.horizontal, 16)
          .padding(.bottom, 12)
        } else if !conflicts.isEmpty {
          Label(
            "Also used by \(ListFormatter.localizedString(byJoining: conflicts)), which wins over the stop shortcut.",
            systemImage: "exclamationmark.triangle.fill"
          )
          .font(.system(size: 11.5))
          .foregroundStyle(Theme.caution)
          .padding(.leading, 54)
          .padding(.trailing, 16)
          .padding(.bottom, 10)
        }
      }
      CardDivider(inset: 54)
      ToggleRow(
        title: "Stop when you switch apps",
        subtitle: "Leaving the app an automation started in stops it. Slated's own windows don't count.",
        symbol: "arrow.left.arrow.right", tint: SettingsPane.automation.tint,
        isOn: $model.configuration.automation.stopOnAppSwitch)
      CardDivider(inset: 54)
      SettingRow(
        title: "Time limit", subtitle: "Stop everything after a while, in case you walk away.", symbol: "timer",
        tint: Color(hex: 0x7A5AF8)
      ) {
        Picker("Time limit", selection: $model.configuration.automation.maxRunMinutes) {
          ForEach(timeLimitChoices, id: \.self) { minutes in
            Text(AutomationLimits.timeLimitTitle(minutes)).tag(minutes)
          }
        }
        .labelsHidden()
        .fixedSize()
      }
      CardDivider(inset: 54)
      SettingRow(
        title: "Show an indicator", subtitle: AutomationIndicatorPreview.settingSubtitle,
        symbol: "record.circle", tint: Color(hex: 0xE5484D)
      ) {
        HStack(spacing: 14) {
          AutomationIndicatorPreview(
            stop: settings.stopShortcut, isOn: settings.showIndicator, inIsland: model.configuration.island.enabled)
          Toggle("Show an indicator", isOn: $model.configuration.automation.showIndicator)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
        }
      }
    }
  }

  private var timeLimitChoices: [Double] {
    let current = model.configuration.automation.maxRunMinutes
    return AutomationLimits.timeLimits.contains(current)
      ? AutomationLimits.timeLimits : (AutomationLimits.timeLimits + [current]).sorted()
  }
}
