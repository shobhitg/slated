import SwiftUI

/// How the settings window arranges its sidebar.
@_spi(Snapshots) public enum SettingsLayout: Sendable {
  /// The real window: a `NavigationSplitView` (a Liquid Glass sidebar on macOS 26).
  case splitView
  /// Sidebar and detail side by side in a plain stack. Used by the snapshot tool, because
  /// `cacheDisplay` can't capture the contents of the glass sidebar.
  case flat
}

/// The settings window's root: a sidebar of panes and the selected pane.
struct SettingsView: View {
  @Bindable var model: AppModel
  var layout: SettingsLayout = .splitView

  var body: some View {
    Group {
      switch layout {
      case .splitView:
        NavigationSplitView {
          SettingsSidebar()
            .navigationSplitViewColumnWidth(min: 200, ideal: 224, max: 280)
        } detail: {
          detail
        }
        .navigationSplitViewStyle(.balanced)
      case .flat:
        HStack(spacing: 0) {
          SettingsSidebar()
            .frame(width: 224)
            .background(Theme.sidebarBackground)
          Rectangle().fill(Theme.hairline).frame(width: 0.5)
          detail
        }
      }
    }
    .environment(model)
    .tint(Theme.accent)
    .frame(minWidth: 940, minHeight: 620)
  }

  private var detail: some View {
    VStack(spacing: 0) {
      if let error = model.loadError {
        LoadErrorBanner(message: error)
      }
      pane
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .background(Theme.paneBackground)
    .overlay(alignment: .bottom) {
      if let toast = model.toast {
        ToastView(toast: toast)
          .padding(.bottom, 18)
          .transition(.move(edge: .bottom).combined(with: .opacity))
          .id(toast.id)
      }
    }
    .animation(Theme.spring, value: model.toast)
    .navigationTitle(model.selectedPane.title)
  }

  @ViewBuilder private var pane: some View {
    switch model.selectedPane {
    case .overview: OverviewPane()
    case .windows: WindowsPane()
    case .hotstrings: HotstringsPane()
    case .clipboard: ClipboardPane()
    case .automation: AutomationPane()
    case .keyboard: KeyboardPane()
    case .layouts: LayoutsPane()
    case .slate: SlateCompatibilityPane()
    case .general: GeneralPane()
    case .about: AboutPane()
    }
  }
}

/// Shown above every pane when config.json can't be read: saving is paused so Slated never
/// overwrites a file the user is in the middle of editing.
private struct LoadErrorBanner: View {
  let message: String
  @Environment(AppModel.self) private var model

  var body: some View {
    Notice(
      style: .error, title: "Slated can't read config.json",
      message: "\(message)\nChanges you make here won't be saved until the file is fixed, so nothing in it is lost."
    ) {
      HStack(spacing: 8) {
        Button("Reveal in Finder") { model.revealConfigurationFile() }
        Button("Reload") { model.reload() }
      }
      .controlSize(.small)
      .padding(.top, 4)
    }
    .padding(.horizontal, Theme.paneHorizontalPadding)
    .padding(.top, 16)
  }
}

/// The scrolling, centered column most panes use.
struct PaneScroll<Content: View>: View {
  var maxWidth: CGFloat = 780
  @ViewBuilder var content: Content

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Theme.sectionSpacing) { content }
        .padding(.horizontal, Theme.paneHorizontalPadding)
        .padding(.top, 24)
        .padding(.bottom, 36)
        .frame(maxWidth: maxWidth, alignment: .leading)
        .frame(maxWidth: .infinity)
    }
    .scrollContentBackground(.hidden)
  }
}
