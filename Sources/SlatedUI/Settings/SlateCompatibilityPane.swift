import SlatedCore
import SwiftUI

/// The Slate files Slated loads alongside its own configuration, with their status and problems.
struct SlateCompatibilityPane: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    @Bindable var model = model
    PaneScroll {
      PaneHeader(
        pane: .slate,
        subtitle: "Your existing ~/.slate.js and ~/.slate keep working, unchanged, next to Slated's own settings.")
      HStack(alignment: .center, spacing: 16) {
        IconTile(symbol: "arrow.triangle.2.circlepath", tint: SettingsPane.slate.tint, size: 36)
        VStack(alignment: .leading, spacing: 4) {
          Text("Load Slate config files").font(.system(size: 14, weight: .semibold))
          Text(
            "Slated runs your Slate bindings, layouts and settings live, and reloads a file the moment you save it. They're read-only here — copy a binding into Slated to edit it in Settings."
          )
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 12)
        Toggle("Load Slate config files", isOn: $model.configuration.general.loadSlateConfigs)
          .labelsHidden()
          .toggleStyle(.switch)
      }
      .cardStyle(padding: 18)
      VStack(alignment: .leading, spacing: 10) {
        SectionHeader(title: "Files", symbol: "doc.on.doc") {
          Button {
            model.reload()
          } label: {
            Label("Reload", systemImage: "arrow.clockwise")
          }
          .buttonStyle(.soft)
          .controlSize(.small)
        }
        ForEach(model.sources) { source in
          SourceCard(source: source, enabled: model.configuration.general.loadSlateConfigs)
        }
        if model.sources.isEmpty {
          Notice(style: .info, title: "No Slate files configured", message: "Add a path below to load a Slate config.")
        }
      }
      PathsCard()
    }
  }
}

private struct SourceCard: View {
  let source: SlateSource
  let enabled: Bool
  @Environment(AppModel.self) private var model

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .center, spacing: 12) {
        IconTile(
          symbol: source.kind == .javascript ? "curlybraces" : "doc.plaintext",
          tint: source.exists ? SettingsPane.slate.tint : Color(hex: 0x8A8A93), size: 32)
        VStack(alignment: .leading, spacing: 3) {
          HStack(spacing: 8) {
            Text(source.displayName).font(.system(size: 13.5, weight: .semibold, design: .monospaced))
            Text(source.kind == .javascript ? "JavaScript" : "Classic")
              .font(.system(size: 10.5, weight: .medium))
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(Theme.well, in: Capsule())
              .foregroundStyle(.secondary)
          }
          Text(summary).font(.system(size: 12)).foregroundStyle(.secondary)
        }
        Spacer(minLength: 8)
        let pill = status
        StatusPill(text: pill.text, color: pill.color, symbol: pill.symbol)
        if source.exists {
          Menu {
            Button("Reveal in Finder") { model.revealFile(atPath: source.path) }
            if let first = source.bindings.first {
              Button("Show Bindings") {
                model.selectedBinding = .source(path: source.path, id: first.id)
                model.selectedPane = .windows
              }
            }
            Button("Copy Path") {
              NSPasteboard.general.clearContents()
              NSPasteboard.general.setString(source.path, forType: .string)
            }
          } label: {
            Image(systemName: "ellipsis.circle").font(.system(size: 14))
          }
          .menuStyle(.borderlessButton)
          .menuIndicator(.hidden)
          .fixedSize()
        }
      }
      .padding(16)
      if !source.diagnostics.isEmpty {
        CardDivider(inset: 0)
        VStack(alignment: .leading, spacing: 8) {
          ForEach(Array(source.diagnostics.enumerated()), id: \.offset) { _, diagnostic in
            DiagnosticRow(diagnostic: diagnostic)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Theme.well.opacity(0.6))
      }
    }
    .cardStyle(padding: 0)
    .opacity(enabled || !source.exists ? 1 : 0.6)
  }

  private var summary: String {
    guard source.exists else { return "Not found — create the file to use it." }
    var parts = ["\(source.bindings.count) binding\(source.bindings.count == 1 ? "" : "s")"]
    if !source.layouts.isEmpty { parts.append("\(source.layouts.count) layout\(source.layouts.count == 1 ? "" : "s")") }
    let errors = source.diagnostics.filter { $0.severity == .error }.count
    let warnings = source.diagnostics.count - errors
    if errors > 0 { parts.append("\(errors) error\(errors == 1 ? "" : "s")") }
    if warnings > 0 { parts.append("\(warnings) warning\(warnings == 1 ? "" : "s")") }
    return parts.joined(separator: " · ")
  }

  private var status: (text: String, color: Color, symbol: String?) {
    if !source.exists { return ("Not found", Theme.neutral, nil) }
    if !enabled { return ("Off", Theme.neutral, nil) }
    if !source.loaded { return ("Failed to load", Theme.critical, "xmark.octagon.fill") }
    if source.errorCount > 0 { return ("Loaded with errors", Theme.caution, "exclamationmark.triangle.fill") }
    return ("Loaded", Theme.positive, nil)
  }
}

private struct DiagnosticRow: View {
  let diagnostic: Diagnostic

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: diagnostic.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
        .font(.system(size: 11))
        .foregroundStyle(diagnostic.severity == .error ? Theme.critical : Theme.caution)
      if let line = diagnostic.line {
        Text("Line \(line)")
          .font(.system(size: 11, weight: .semibold, design: .monospaced))
          .foregroundStyle(.secondary)
          .frame(minWidth: 52, alignment: .leading)
      }
      Text(diagnostic.message)
        .font(.system(size: 12))
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
    }
  }
}

/// Which Slate files to load, in order.
private struct PathsCard: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    let paths = model.configuration.general.slateConfigPaths
    SettingsCard(
      title: "Paths", symbol: "folder",
      footer: "Files load in this order; a later file's settings win. ~ means your home folder."
    ) {
      ForEach(paths.indices, id: \.self) { index in
        if index > 0 { CardDivider() }
        HStack(spacing: 10) {
          Image(systemName: "doc").foregroundStyle(.secondary)
          TextField("~/.slate.js", text: pathBinding(index))
            .textFieldStyle(.plain)
            .font(.system(size: 12.5, design: .monospaced))
          Button {
            model.configuration.general.slateConfigPaths.remove(at: index)
          } label: {
            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
          }
          .buttonStyle(.plain)
          .help("Stop loading this file")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
      }
      CardDivider(inset: 0)
      HStack {
        Button {
          model.configuration.general.slateConfigPaths.append("")
        } label: {
          Label("Add Path", systemImage: "plus")
        }
        .buttonStyle(.link)
        Spacer()
        if paths != GeneralSettings().slateConfigPaths {
          Button("Restore Defaults") {
            model.configuration.general.slateConfigPaths = GeneralSettings().slateConfigPaths
          }
          .buttonStyle(.link)
        }
      }
      .font(.system(size: 12.5))
      .padding(.horizontal, 16)
      .padding(.vertical, 10)
    }
  }

  private func pathBinding(_ index: Int) -> Binding<String> {
    Binding(
      get: {
        let paths = model.configuration.general.slateConfigPaths
        return paths.indices.contains(index) ? paths[index] : ""
      },
      set: { newValue in
        guard model.configuration.general.slateConfigPaths.indices.contains(index) else { return }
        model.configuration.general.slateConfigPaths[index] = newValue
      })
  }
}
