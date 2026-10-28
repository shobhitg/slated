import SlatedCore
import SwiftUI

/// Get Started, the main window's setup page: welcome, Accessibility permission, Hyper key, Slate
/// config, done. The step lives on the model (`getStartedStep`), so the app can move it on when
/// Accessibility is granted, and the window reopens where the user left off.
struct GetStartedPane: View {
  @Environment(AppModel.self) private var model
  @State private var forward = true

  var body: some View {
    let step = model.getStartedStep
    VStack(spacing: 0) {
      ZStack {
        stepView(step)
          .id(step)
          .transition(
            .asymmetric(
              insertion: .offset(x: forward ? 40 : -40).combined(with: .opacity),
              removal: .offset(x: forward ? -40 : 40).combined(with: .opacity)))
      }
      .frame(maxWidth: 660, maxHeight: .infinity)
      .frame(maxWidth: .infinity)
      .padding(.horizontal, 40)
      .padding(.top, 24)
      footer(step)
    }
    .background(GetStartedBackdrop())
    .animation(Theme.spring, value: step)
  }

  @ViewBuilder private func stepView(_ step: GetStartedStep) -> some View {
    switch step {
    case .welcome: WelcomeStep()
    case .accessibility: AccessibilityStep()
    case .hyperKey: HyperKeyStep()
    case .slateConfig: SlateConfigStep()
    case .done: DoneStep()
    }
  }

  private func footer(_ step: GetStartedStep) -> some View {
    // Equal flexible sides keep the progress dots centered whatever the button titles are. (A stack, not
    // a Group: an empty Group takes no space, which pushed the dots to the left on the first step.)
    HStack(spacing: 12) {
      HStack {
        if step != .welcome && step != .done {
          Button("Back") { go(-1) }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .keyboardShortcut(.cancelAction)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      ProgressDots(step: step)
      Button(primaryTitle(step)) {
        if step == .done { model.finishGetStarted() } else { go(1) }
      }
      .buttonStyle(.gradientLarge)
      .keyboardShortcut(.defaultAction)
      .frame(maxWidth: .infinity, alignment: .trailing)
    }
    .padding(.horizontal, 28)
    .padding(.vertical, 20)
  }

  private func primaryTitle(_ step: GetStartedStep) -> String {
    switch step {
    case .welcome: return "Set Up Slated"
    case .accessibility: return model.runtimeStatus.accessibilityGranted ? "Continue" : "Skip for Now"
    case .hyperKey, .slateConfig: return "Continue"
    case .done: return "Start Using Slated"
    }
  }

  private func go(_ delta: Int) {
    guard let next = GetStartedStep(rawValue: model.getStartedStep.rawValue + delta) else { return }
    forward = delta > 0
    withAnimation(Theme.spring) { model.getStartedStep = next }
  }
}

private struct ProgressDots: View {
  let step: GetStartedStep

  var body: some View {
    HStack(spacing: 6) {
      ForEach(GetStartedStep.allCases, id: \.self) { item in
        Capsule()
          .fill(
            item == step
              ? AnyShapeStyle(Theme.accentGradientHorizontal)
              : AnyShapeStyle(Color.primary.opacity(item.rawValue < step.rawValue ? 0.35 : 0.14))
          )
          .frame(width: item == step ? 22 : 7, height: 7)
      }
    }
    .animation(Theme.spring, value: step)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Step \(step.rawValue + 1) of \(GetStartedStep.allCases.count)")
  }
}

/// Soft accent light behind the Get Started content.
private struct GetStartedBackdrop: View {
  var body: some View {
    ZStack {
      Theme.paneBackground
      RadialGradient(
        colors: [Theme.accentStops[0].opacity(0.16), .clear], center: .topLeading, startRadius: 0, endRadius: 420)
      RadialGradient(
        colors: [Theme.accentStops[2].opacity(0.14), .clear], center: .topTrailing, startRadius: 0, endRadius: 380)
      RadialGradient(
        colors: [Theme.accentStops[1].opacity(0.07), .clear], center: .bottom, startRadius: 0, endRadius: 360)
    }
    .ignoresSafeArea()
  }
}

/// Title and subtitle shared by every step.
struct StepTitle: View {
  let title: String
  let subtitle: String

  var body: some View {
    VStack(spacing: 10) {
      Text(title)
        .font(.system(size: 28, weight: .bold))
        .tracking(-0.6)
        .multilineTextAlignment(.center)
      Text(subtitle)
        .font(.system(size: 14))
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 470)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}
