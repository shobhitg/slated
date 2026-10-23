import SlatedCore
import SwiftUI

/// Automations running right now, live: what each one does, the shortcut that started it, how long
/// it has run and how many times, with Stop All. Used by the Automation pane and the Overview.
struct RunningAutomationsCard: View {
  /// Shows nothing at all while idle (the Overview), instead of the quiet "nothing running" row.
  var hidesWhenIdle = false
  @Environment(AppModel.self) private var model

  var body: some View {
    let running = model.activeAutomations
    if !running.isEmpty {
      VStack(alignment: .leading, spacing: 0) {
        HStack(spacing: 10) {
          LiveDot()
          VStack(alignment: .leading, spacing: 1) {
            Text(running.count == 1 ? "1 automation running" : "\(running.count) automations running")
              .font(.system(size: 13.5, weight: .semibold))
            Text(stopHint).font(.system(size: 11.5)).foregroundStyle(.secondary)
          }
          Spacer(minLength: 8)
          if let stop = model.configuration.automation.stopShortcut {
            KeyComboView(combo: stop, size: .small).help("The stop shortcut works from any app.")
          }
          Button {
            model.stopAutomations()
          } label: {
            Label("Stop All", systemImage: "stop.fill")
          }
          .buttonStyle(StopButtonStyle())
          .keyboardShortcut(".", modifiers: .command)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        ForEach(running) { automation in
          CardDivider(inset: running.first == automation ? 0 : 56)
          RunningAutomationRow(automation: automation)
        }
      }
      .background {
        ZStack {
          Theme.cardBackground
          LinearGradient(
            colors: [Theme.critical.opacity(0.07), .clear], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
      }
      .overlay(
        RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
          .strokeBorder(Theme.critical.opacity(0.3), lineWidth: 1)
      )
      .shadow(color: Theme.critical.opacity(0.12), radius: 14, y: 4)
      .task(id: running.map(\.id)) {
        // Repetition counts change between notifications; poll while anything runs.
        while !Task.isCancelled {
          try? await Task.sleep(for: .milliseconds(500))
          model.refreshAutomations()
        }
      }
      .transition(.opacity.combined(with: .scale(scale: 0.98)))
    } else if !hidesWhenIdle {
      HStack(spacing: 12) {
        Image(systemName: "moon.zzz.fill")
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(.secondary)
          .frame(width: 30, height: 30)
          .background(Theme.well, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        VStack(alignment: .leading, spacing: 2) {
          Text("Nothing running").font(.system(size: 13, weight: .medium))
          Text("Press an automation's shortcut to start it. It shows up here with a Stop button.")
            .font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
        Spacer(minLength: 8)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
      .cardStyle(padding: 0)
    }
  }

  private var stopHint: String {
    let settings = model.configuration.automation
    var parts: [String] = []
    if settings.stopOnAppSwitch { parts.append("Stops when you switch apps") }
    if settings.maxRunMinutes > 0 {
      parts.append("or after \(AutomationLimits.timeLimitTitle(settings.maxRunMinutes))")
    }
    return parts.isEmpty ? "Runs until you stop it" : parts.joined(separator: " ")
  }
}

/// One running automation: its name, what it does, the shortcut, elapsed time and runs.
struct RunningAutomationRow: View {
  let automation: ActiveAutomation
  var compact = false
  @Environment(AppModel.self) private var model

  var body: some View {
    let binding = model.binding(for: automation)
    HStack(spacing: 12) {
      AutomationThumbnail(action: binding?.action, compact: compact)
      VStack(alignment: .leading, spacing: 1) {
        Text(model.title(for: automation))
          .font(.system(size: compact ? 12.5 : 13, weight: .medium))
          .lineLimit(1)
        Text(binding.map { AutomationDescriber.sentence($0.action) } ?? automation.title)
          .font(.system(size: compact ? 11 : 11.5))
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer(minLength: 8)
      if !compact, let keys = automation.triggerKeys {
        KeyComboView(combo: keys, size: .small)
      }
      VStack(alignment: .trailing, spacing: 1) {
        TimelineView(.periodic(from: automation.startedAt, by: 1)) { context in
          Text(Self.elapsed(from: automation.startedAt, to: context.date))
            .font(.system(size: compact ? 11.5 : 12.5, weight: .semibold, design: .rounded).monospacedDigit())
        }
        Text(runs).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.secondary)
      }
      .frame(minWidth: 52, alignment: .trailing)
    }
    .padding(.horizontal, compact ? 8 : 16)
    .padding(.vertical, compact ? 6 : 10)
  }

  private var runs: String {
    if automation.id.hasPrefix("hold:") { return "held" }
    return automation.repetitions == 1 ? "1 run" : "\(automation.repetitions.formatted()) runs"
  }

  /// "0:07", "12:40", "1:02:03".
  static func elapsed(from start: Date, to now: Date) -> String {
    let total = max(0, Int(now.timeIntervalSince(start)))
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let seconds = total % 60
    return hours > 0
      ? String(format: "%d:%02d:%02d", hours, minutes, seconds) : String(format: "%d:%02d", minutes, seconds)
  }
}

/// A small drawing of what an automation does: its recipe's art when it matches one, else the
/// operation's glyph. Shared by lists of automations and of running ones.
struct AutomationThumbnail: View {
  let action: Action?
  var compact = false

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: compact ? 7 : 9, style: .continuous).fill(Theme.well)
      if let action, let recipe = AutomationRecipes.all.first(where: { $0.matches(action) }) {
        RecipeArt(art: recipe.art, scale: compact ? 0.4 : 0.5)
      } else if let action {
        ActionGlyph(action: action, width: compact ? 24 : 30, height: compact ? 17 : 22)
      } else {
        Image(systemName: "repeat").font(.system(size: compact ? 10 : 12, weight: .bold))
          .foregroundStyle(Theme.accentGradient)
      }
    }
    .frame(width: compact ? 34 : 46, height: compact ? 28 : 38)
    .accessibilityHidden(true)
  }
}

/// A red, high-contrast button for stopping automations.
struct StopButtonStyle: ButtonStyle {
  var compact = false
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: compact ? 11.5 : 12.5, weight: .semibold))
      .foregroundStyle(.white)
      .padding(.horizontal, compact ? 10 : 13)
      .frame(height: compact ? 24 : 28)
      .background {
        RoundedRectangle(cornerRadius: compact ? 7 : 8, style: .continuous)
          .fill(
            LinearGradient(
              colors: [Color(hex: 0xF2555A), Color(hex: 0xD93036)], startPoint: .top, endPoint: .bottom)
          )
          .overlay(
            RoundedRectangle(cornerRadius: compact ? 7 : 8, style: .continuous)
              .strokeBorder(.white.opacity(0.22), lineWidth: 0.6))
      }
      .shadow(color: Theme.critical.opacity(isEnabled ? 0.35 : 0), radius: 6, y: 2)
      .opacity(isEnabled ? 1 : 0.45)
      .scaleEffect(configuration.isPressed ? 0.97 : 1)
      .animation(Theme.snappy, value: configuration.isPressed)
  }
}
