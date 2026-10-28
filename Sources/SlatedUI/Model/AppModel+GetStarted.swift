import Foundation

/// Get Started (first-run setup, a page of the main window) and the pane the window opens on.
extension AppModel {
  /// Setup isn't finished: Get Started was never completed, or Slated doesn't have Accessibility
  /// access (without it, it can't move windows or type hotstrings).
  public var needsSetup: Bool { !setupFinished || !runtimeStatus.accessibilityGranted }

  /// Get Started is in the sidebar during setup, and while it's open (Help → Get Started, Overview).
  var showsGetStarted: Bool { needsSetup || selectedPane == .getStarted }

  /// Call as the main window comes up. A window that was closed opens on Get Started during setup
  /// (at the permission step when that's all that's left) and on Overview otherwise: never on the
  /// pane it was last left on, where an empty state ("No hotstrings yet") read like a step to do. A
  /// window that's still open keeps its pane.
  public func prepareToShowMainWindow(wasOpen: Bool) {
    guard !wasOpen else { return }
    if needsSetup {
      if setupFinished { getStartedStep = .accessibility }
      selectedPane = .getStarted
    } else {
      selectedPane = .overview
    }
  }

  /// Opens Get Started on request. After setup it starts over from the welcome; during setup it
  /// picks up where it was.
  public func showGetStarted() {
    if !needsSetup {
      getStartedStep = .welcome
    } else if setupFinished {
      getStartedStep = .accessibility
    }
    selectedPane = .getStarted
  }

  /// The last step's button: setup is done (kept across launches) and the window moves on to Overview.
  func finishGetStarted() {
    services.setupFinished = true
    setupFinished = true
    selectedPane = .overview
  }

  /// The app reported Accessibility access just now (the user switched it on in System Settings):
  /// Get Started moves past its permission step, to the next one, or to the end when the rest was
  /// done before.
  func accessibilityWasGranted() {
    guard getStartedStep.rawValue <= GetStartedStep.accessibility.rawValue else { return }
    getStartedStep = setupFinished ? .done : .hyperKey
    if selectedPane == .getStarted {
      showToast("Accessibility is on: Slated can move your windows now")
    }
  }
}
