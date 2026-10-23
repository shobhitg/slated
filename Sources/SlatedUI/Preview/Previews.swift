#if DEBUG
  import SwiftUI

  // Xcode previews over `PreviewServices`, mirroring what `swift run SlatedUISnapshots` renders.
  // `PreviewProvider` rather than `#Preview`: the macro's plugin ships with Xcode, and this package
  // must build with the Command Line Tools alone.

  struct SettingsViewPreviews: PreviewProvider {
    static var previews: some View {
      ForEach(SettingsPane.allCases) { pane in
        SettingsView(model: model(.configured, pane: pane))
          .frame(width: SlatedUI.settingsWindowSize.width, height: SlatedUI.settingsWindowSize.height)
          .previewDisplayName(pane.title)
      }
      SettingsView(model: model(.empty, pane: .windows))
        .frame(width: SlatedUI.settingsWindowSize.width, height: SlatedUI.settingsWindowSize.height)
        .previewDisplayName("Empty")
      SettingsView(model: model(.brokenConfig, pane: .overview))
        .frame(width: SlatedUI.settingsWindowSize.width, height: SlatedUI.settingsWindowSize.height)
        .previewDisplayName("Broken config.json")
    }

    private static func model(_ scenario: PreviewServices.Scenario, pane: SettingsPane) -> AppModel {
      let model = AppModel(services: PreviewServices(scenario: scenario))
      model.selectedPane = pane
      model.selectedBinding = model.configuration.bindings.first.map { .slated($0.id) }
      model.selectedHotstringID = model.configuration.hotstrings.first?.id
      model.selectedLayout = model.configuration.layouts.first.map { .slated(name: $0.name) }
      return model
    }
  }

  struct OnboardingViewPreviews: PreviewProvider {
    static var previews: some View {
      ForEach(OnboardingStep.allCases, id: \.self) { step in
        OnboardingView(model: AppModel(services: PreviewServices(scenario: .firstRun)), initialStep: step, onFinish: {})
          .previewDisplayName("Onboarding \(step.rawValue + 1)")
      }
    }
  }

  struct MenuBarViewPreviews: PreviewProvider {
    static var previews: some View {
      MenuBarView(model: AppModel(services: PreviewServices()), actions: MenuBarActions(openSettings: {}, quit: {}))
        .previewDisplayName("Menu bar")
      MenuBarView(
        model: AppModel(services: PreviewServices(scenario: .firstRun)),
        actions: MenuBarActions(openSettings: {}, quit: {})
      )
      .previewDisplayName("Menu bar, first run")
    }
  }

  struct ComponentGalleryPreviews: PreviewProvider {
    static var previews: some View { ComponentGallery() }
  }
#endif
