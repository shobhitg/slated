import SlatedCore
import SwiftUI

/// The sidebar's foot: "All changes saved" and friends, so it's clear there's no Save button to look
/// for, a moment's "Updated from config.json" when a hand edit is picked up, and Reload.
struct SaveStatusFooter: View {
  var rail = false
  @Environment(AppModel.self) private var model

  var body: some View {
    let status = SaveStatusText(model: model)
    let updated = model.updatedFromDisk
    Group {
      if rail {
        VStack(spacing: 10) {
          Image(systemName: updated.isEmpty ? status.symbol : "arrow.down.doc.fill")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(updated.isEmpty ? status.color : Theme.accent)
            .help(updated.isEmpty ? "\(status.short). \(status.help)" : SaveStatusText.updated(updated))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(updated.isEmpty ? status.short : SaveStatusText.updated(updated))
          ReloadButton()
        }
        .frame(maxWidth: .infinity)
      } else {
        HStack(alignment: .center, spacing: 6) {
          VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
              Image(systemName: status.symbol).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(
                status.color)
              Text(status.short).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            .help(status.help)
            .accessibilityElement(children: .combine)
            if !updated.isEmpty {
              Label {
                LinkedText(SaveStatusText.updated(updated), underline: true)
              } icon: {
                Image(systemName: "arrow.down.doc.fill")
              }
              .font(.system(size: 11))
              .foregroundStyle(Theme.accent)
              .lineLimit(1)
              .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
          }
          Spacer(minLength: 0)
          ReloadButton()
        }
        .padding(.leading, 18)
        .padding(.trailing, 12)
      }
    }
    .padding(.vertical, 10)
    .animation(Theme.snappy, value: model.saveState)
    .animation(Theme.snappy, value: updated)
  }
}

/// Re-reads config.json and settings.json.
private struct ReloadButton: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    Button {
      model.reload()
    } label: {
      Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
    }
    .buttonStyle(.borderless)
    .foregroundStyle(.secondary)
    .help("Reload config.json and settings.json")
    .accessibilityLabel("Reload config.json and settings.json")
  }
}

/// What the save state says, in the sidebar's short form and General's longer one.
@MainActor
struct SaveStatusText {
  let model: AppModel

  var short: String {
    switch model.saveState {
    case .saved: return "All changes saved"
    case .pending: return "Saving…"
    case .partiallySaved(let count): return count == 1 ? "1 item has errors" : "\(count) items have errors"
    case .failed: return "Couldn't save"
    case .blocked: return "Saving paused"
    case .conflict: return "Waiting for your choice"
    }
  }

  /// General's configuration card.
  var long: String {
    switch model.saveState {
    case .saved, .pending: return short
    case .partiallySaved(let count):
      return "\(count) item\(count == 1 ? "" : "s") not saved — fix the errors shown"
    case .failed(let message): return "Couldn't save: \(message)"
    case .blocked: return "Saving paused until \(model.unreadableFileName) can be read"
    case .conflict: return "Not saved: \(conflictNames) changed on disk"
    }
  }

  var symbol: String {
    switch model.saveState {
    case .saved: return "checkmark.circle.fill"
    case .pending: return "arrow.triangle.2.circlepath"
    case .failed: return "xmark.octagon.fill"
    case .partiallySaved, .blocked, .conflict: return "exclamationmark.triangle.fill"
    }
  }

  var color: Color {
    switch model.saveState {
    case .saved: return Theme.positive
    case .pending: return .secondary
    case .partiallySaved, .blocked, .conflict: return Theme.caution
    case .failed: return Theme.critical
    }
  }

  var help: String {
    switch model.saveState {
    // file link: a tooltip
    case .saved: return "Changes are saved to config.json and settings.json as you make them."
    case .pending: return "Saving…"
    case .partiallySaved: return "Items with errors keep their last saved version until they're fixed."
    case .failed(let message): return message
    case .blocked: return "\(model.unreadableFileName) can't be read, so Slated won't overwrite it."
    case .conflict:
      return "\(conflictNames) changed on disk while you had unsaved changes. Choose a version in the banner."
    }
  }

  private var conflictNames: String {
    ConfigFile.allCases.filter(model.conflict.contains).map(\.rawValue).joined(separator: " and ")
  }

  /// "Updated from config.json", "Updated from config.json and settings.json".
  static func updated(_ files: [ConfigFile]) -> String {
    "Updated from " + files.map(\.rawValue).joined(separator: " and ")
  }
}

/// "All changes saved" in words, for General's configuration card.
struct SaveStatusLabel: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    let status = SaveStatusText(model: model)
    Label {
      HStack(spacing: 6) {
        LinkedText(status.long).lineLimit(2)
        if !model.updatedFromDisk.isEmpty {
          LinkedText(SaveStatusText.updated(model.updatedFromDisk), underline: true).foregroundStyle(Theme.accent)
            .lineLimit(1)
        }
      }
    } icon: {
      Image(systemName: status.symbol).foregroundStyle(status.color)
    }
    .font(.system(size: 12))
    .foregroundStyle(.secondary)
  }
}

/// Shown above every pane when a file changed on disk while the window had unsaved edits in it: the
/// user picks the version, never Slated.
struct ConflictBanner: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    let files = ConfigFile.allCases.filter(model.conflict.contains)
    let names = files.map(\.rawValue).joined(separator: " and ")
    Notice(
      style: .warning, title: "\(names) changed on disk",
      message: "You have changes here that aren't saved yet. Reload from File shows the file and drops your "
        + "changes to it; Keep My Changes saves your version over the file's."
    ) {
      HStack(spacing: 8) {
        Button("Reload from File") { model.reloadConflictingFiles() }
        Button("Keep My Changes") { model.keepMyChanges() }
        if files.count == 1, let file = files.first {
          Button("Open \(file.rawValue)") { model.openConfigFile(file) }
            .buttonStyle(.link)
        }
      }
      .controlSize(.small)
      .padding(.top, 4)
    }
    .padding(.horizontal, Theme.paneHorizontalPadding)
    .padding(.top, 16)
  }
}
