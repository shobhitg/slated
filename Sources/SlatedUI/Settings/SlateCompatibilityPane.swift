import SlatedCore
import SwiftUI

/// Importing a Slate config: Slated doesn't run `~/.slate.js` or `~/.slate`, but copies what they set
/// up into its own config, as many times as you like.
struct SlateCompatibilityPane: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    PaneScroll {
      PaneHeader(
        pane: .slate,
        subtitle: "Bring the shortcuts, layouts and settings of a Slate config into Slated, where you can change them.")
      HStack(alignment: .center, spacing: 16) {
        IconTile(symbol: "square.and.arrow.down", tint: SettingsPane.slate.tint, size: 36)
        VStack(alignment: .leading, spacing: 4) {
          LinkedText(model.slateConfigPath.map { "Import \($0)" } ?? "No Slate config here")
            .font(.system(size: 14, weight: .semibold))
          LinkedText(detail)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 12)
        Button("Import") { model.importSlateConfigFromUI() }
          .buttonStyle(.gradient)
          .disabled(model.slateConfigPath == nil)
      }
      .cardStyle(padding: 18)
      if let report = model.lastSlateImport ?? model.slateImportNotice {
        LastImportCard(report: report)
      }
      Notice(
        style: .info, title: "Slated doesn't run Slate files",
        message:
          "An import copies your Slate config into ~/.config/slated/config.json (shortcuts, layouts, display "
          + "defaults) and settings.json (Slate's config values). Your Slate file stays as it is; edit what was "
          + "imported here instead. Importing again adds only what Slated doesn't have yet.")
    }
  }

  private var detail: String {
    guard model.slateConfigPath != nil else {
      // file link: LinkedText(detail)
      return "Slated looks for ~/.slate.js, then ~/.slate, in your home folder."
    }
    return "Shortcuts on keys Slated already uses are left out, so you can import again any time."
  }
}

/// What the last import did, in plain words.
private struct LastImportCard: View {
  let report: SlateImportReport

  var body: some View {
    SettingsCard(title: "Last Import", symbol: "clock.arrow.circlepath") {
      FactRow(label: "From", value: report.fileNames, monospaced: true)
      CardDivider()
      FactRow(label: "Shortcuts added", value: "\(report.added)")
      if report.alreadyThere > 0 {
        CardDivider()
        FactRow(label: "Already in Slated", value: "\(report.alreadyThere)")
      }
      if report.layoutsAdded > 0 {
        CardDivider()
        FactRow(label: "Layouts added", value: "\(report.layoutsAdded)")
      }
      if !report.notConverted.isEmpty {
        CardDivider()
        VStack(alignment: .leading, spacing: 6) {
          Text("Couldn't be converted").font(.system(size: 12.5, weight: .medium))
          ForEach(Array(report.notConverted.enumerated()), id: \.offset) { _, item in
            HStack(alignment: .firstTextBaseline, spacing: 8) {
              Text(item.displayName).font(.system(size: 11.5, weight: .semibold, design: .monospaced))
              Text(item.reason).font(.system(size: 11.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
      }
      if !report.problems.isEmpty {
        CardDivider()
        VStack(alignment: .leading, spacing: 6) {
          Text("May not match your Mac").font(.system(size: 12.5, weight: .medium))
          ForEach(report.problems, id: \.self) { problem in
            Text(problem).font(.system(size: 11.5)).foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
      }
    }
  }
}
