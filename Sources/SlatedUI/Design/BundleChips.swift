import SwiftUI

/// A titled group of apps in an "Add App" menu: "Games", "Password Managers", "Running Apps".
struct AppChoiceSection: Identifiable {
  var id: String { title }
  var title: String
  var apps: [AppModel.AppChoice]
}

/// Apps by bundle identifier, as removable chips with icons, plus an "Add App" menu. Used for
/// hotstring app filters, per-app shortcuts and the clipboard's excluded apps.
struct BundleChips: View {
  @Binding var ids: [String]
  var emptyText: String?
  /// What the menu offers; apps already in `ids` are left out.
  var sections: [AppChoiceSection]
  var addTitle = "Add App"
  @Environment(AppModel.self) private var model

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      FlowLayout(spacing: 6) {
        ForEach(ids, id: \.self) { id in
          HStack(spacing: 6) {
            AppIconView(bundleID: id, size: 16)
            Text(model.appName(bundleID: id)).font(.system(size: 12.5))
            Button {
              withAnimation(Theme.snappy) { ids.removeAll { $0 == id } }
            } label: {
              Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Remove")
            .accessibilityLabel("Remove \(model.appName(bundleID: id))")
          }
          .padding(.leading, 6)
          .padding(.trailing, 9)
          .padding(.vertical, 5)
          .background(Theme.cardBackground, in: Capsule())
          .overlay(Capsule().strokeBorder(Theme.wellStroke))
          .help(id)
        }
        Menu {
          let available = sections.map { section in
            AppChoiceSection(title: section.title, apps: section.apps.filter { !ids.contains($0.bundleID) })
          }.filter { !$0.apps.isEmpty }
          if available.isEmpty {
            Text("No other apps are running")
          }
          ForEach(available) { section in
            Section(section.title) {
              ForEach(section.apps) { app in
                Button(app.name) { withAnimation(Theme.snappy) { ids.append(app.bundleID) } }
              }
            }
          }
        } label: {
          Label(addTitle, systemImage: "plus")
            .font(.system(size: 12.5, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
      }
      if ids.isEmpty, let emptyText { Hint(emptyText) }
    }
  }
}

extension AppModel {
  /// Running apps (with bundle identifiers) as menu choices.
  var runningAppChoices: [AppChoice] {
    runningApps.compactMap { app in
      app.bundleID.map { AppChoice(bundleID: $0, name: app.name, path: app.path, isDefault: false) }
    }
  }

  /// Menu sections for picking a game or any running app: games first when any are running.
  var gameFirstSections: [AppChoiceSection] {
    let games = Set(runningGames.compactMap(\.bundleID))
    let all = runningAppChoices
    let gameChoices = all.filter { games.contains($0.bundleID) }
    let others = all.filter { !games.contains($0.bundleID) }
    return gameChoices.isEmpty
      ? [AppChoiceSection(title: "Running Apps", apps: others)]
      : [
        AppChoiceSection(title: "Games", apps: gameChoices),
        AppChoiceSection(title: "Other Running Apps", apps: others),
      ]
  }
}
