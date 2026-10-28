import Foundation

@testable import SlatedCore
@testable import SlatedUI

// Get Started (first-run setup, a page of the main window) and the pane the main window opens on.
// SlatedUI is main-actor isolated; the harness runs every test on the main thread.

private func onMain(_ body: @MainActor () throws -> Void) throws {
  try MainActor.assumeIsolated(body)
}

let uiGetStartedTests = Suite(
  "UIGetStarted",
  [
    (
      "the main window opens on Get Started during setup and on Overview after, never on the last pane",
      {
        try onMain {
          let firstRun = AppModel(services: PreviewServices(scenario: .firstRun))
          firstRun.prepareToShowMainWindow(wasOpen: false)
          expectEqual(firstRun.selectedPane, .getStarted)
          expectEqual(firstRun.getStartedStep, .welcome)
          // An open window keeps whatever the user is looking at.
          firstRun.selectedPane = .windows
          firstRun.prepareToShowMainWindow(wasOpen: true)
          expectEqual(firstRun.selectedPane, .windows)

          // Set up: a reopened window shows Overview, not the empty pane it was closed on.
          let configured = AppModel(services: PreviewServices(scenario: .empty))
          configured.selectedPane = .hotstrings
          configured.prepareToShowMainWindow(wasOpen: false)
          expectEqual(configured.selectedPane, .overview)
          configured.selectedPane = .hotstrings
          configured.prepareToShowMainWindow(wasOpen: true)
          expectEqual(configured.selectedPane, .hotstrings)
        }
      }
    ),
    (
      "with only Accessibility missing, the window opens on Get Started's permission step",
      {
        try onMain {
          let services = PreviewServices()
          services.setAccessibilityGranted(false)
          let model = AppModel(services: services)
          expect(model.needsSetup)
          model.prepareToShowMainWindow(wasOpen: false)
          expectEqual(model.selectedPane, .getStarted)
          expectEqual(model.getStartedStep, .accessibility)
        }
      }
    ),
    (
      "Get Started is in the sidebar during setup and while open, and leads it",
      {
        try onMain {
          let firstRun = AppModel(services: PreviewServices(scenario: .firstRun))
          expect(firstRun.showsGetStarted)
          expectEqual(SettingsSidebar.sections(showingGetStarted: true).first, [.getStarted])
          expect(!SettingsSidebar.sections(showingGetStarted: false).joined().contains(.getStarted))

          let configured = AppModel(services: PreviewServices())
          expect(!configured.needsSetup && !configured.showsGetStarted)
          // Opened again after setup (Help → Get Started): from the welcome, in the sidebar while open.
          configured.getStartedStep = .done
          configured.showGetStarted()
          expectEqual(configured.selectedPane, .getStarted)
          expectEqual(configured.getStartedStep, .welcome)
          expect(configured.showsGetStarted)
          configured.selectedPane = .overview
          expect(!configured.showsGetStarted)
        }
      }
    ),
    (
      "Accessibility switched on moves Get Started past the permission step, with a confirmation",
      {
        try onMain {
          let services = PreviewServices(scenario: .firstRun)
          let model = AppModel(services: services)
          model.prepareToShowMainWindow(wasOpen: false)
          model.getStartedStep = .accessibility
          services.setAccessibilityGranted(true)  // the app reports it within a second
          expectEqual(model.getStartedStep, .hyperKey)
          expect(model.toast?.message.contains("Accessibility is on") == true, "\(String(describing: model.toast))")
          expect(model.showsGetStarted, "setup isn't finished yet")

          // Already past the step: stays where the user is.
          let ahead = PreviewServices(scenario: .firstRun)
          let aheadModel = AppModel(services: ahead)
          aheadModel.getStartedStep = .slateConfig
          ahead.setAccessibilityGranted(true)
          expectEqual(aheadModel.getStartedStep, .slateConfig)

          // Set up before, back only for the permission: on to the end.
          let returning = PreviewServices()
          returning.setAccessibilityGranted(false)
          let returningModel = AppModel(services: returning)
          returningModel.prepareToShowMainWindow(wasOpen: false)
          returning.setAccessibilityGranted(true)
          expectEqual(returningModel.getStartedStep, .done)
        }
      }
    ),
    (
      "finishing Get Started is kept across launches and lands on Overview",
      {
        try onMain {
          let services = PreviewServices(scenario: .firstRun)
          let model = AppModel(services: services)
          model.prepareToShowMainWindow(wasOpen: false)
          model.getStartedStep = .done
          model.finishGetStarted()
          expect(services.setupFinished)
          expectEqual(model.selectedPane, .overview)
          // Accessibility is still off: Get Started stays in the sidebar, at the permission step.
          let relaunched = AppModel(services: services)
          expect(relaunched.setupFinished && relaunched.needsSetup)
          relaunched.prepareToShowMainWindow(wasOpen: false)
          expectEqual(relaunched.getStartedStep, .accessibility)
          services.setAccessibilityGranted(true)
          expect(!relaunched.needsSetup)
          relaunched.selectedPane = .overview
          expect(!relaunched.showsGetStarted)
        }
      }
    ),
  ])
