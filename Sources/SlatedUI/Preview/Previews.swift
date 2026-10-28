#if DEBUG
  import SwiftUI

  // Xcode previews over `PreviewServices`, mirroring what `swift run SlatedUISnapshots` renders.
  // `PreviewProvider` rather than `#Preview`: the macro's plugin ships with Xcode, and this package
  // must build with the Command Line Tools alone.

  struct SettingsViewPreviews: PreviewProvider {
    static var previews: some View {
      ForEach(SettingsPane.allCases) { pane in
        SettingsView(model: model(.configured, pane: pane))
          .frame(width: SlatedUI.mainWindowSize.width, height: SlatedUI.mainWindowSize.height)
          .previewDisplayName(pane.title)
      }
      SettingsView(model: model(.empty, pane: .windows))
        .frame(width: SlatedUI.mainWindowSize.width, height: SlatedUI.mainWindowSize.height)
        .previewDisplayName("Empty")
      SettingsView(model: model(.brokenConfig, pane: .overview))
        .frame(width: SlatedUI.mainWindowSize.width, height: SlatedUI.mainWindowSize.height)
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

  struct GetStartedPreviews: PreviewProvider {
    static var previews: some View {
      ForEach(GetStartedStep.allCases, id: \.self) { step in
        SettingsView(model: model(step))
          .frame(width: SlatedUI.mainWindowSize.width, height: SlatedUI.mainWindowSize.height)
          .previewDisplayName("Get Started \(step.rawValue + 1)")
      }
    }

    private static func model(_ step: GetStartedStep) -> AppModel {
      let model = AppModel(services: PreviewServices(scenario: .firstRun))
      model.selectedPane = .getStarted
      model.getStartedStep = step
      return model
    }
  }

  struct ComponentGalleryPreviews: PreviewProvider {
    static var previews: some View { ComponentGallery() }
  }

  struct ClipboardPickerPreviews: PreviewProvider {
    static var previews: some View {
      ClipboardPickerView(model: ClipboardPickerModel(services: PreviewServices()))
        .previewDisplayName("Clipboard picker")
      ClipboardPickerView(model: ClipboardPickerModel(services: PreviewServices(scenario: .empty)))
        .previewDisplayName("Clipboard picker, empty")
    }
  }

  struct AutomationRunningPreviews: PreviewProvider {
    static var previews: some View {
      let services = PreviewServices()
      services.automations = PreviewServices.sampleAutomations()
      let model = AppModel(services: services)
      model.selectedPane = .automation
      return SettingsView(model: model)
        .frame(width: SlatedUI.mainWindowSize.width, height: SlatedUI.mainWindowSize.height)
        .previewDisplayName("Automation, running")
    }
  }
#endif
