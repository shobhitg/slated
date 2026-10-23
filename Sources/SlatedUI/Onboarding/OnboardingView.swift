import SlatedCore
import SwiftUI

/// The steps of the first-run flow, in order.
@_spi(Snapshots) public enum OnboardingStep: Int, CaseIterable, Sendable {
  case welcome, accessibility, hyperKey, slateConfig, done
}

/// A short first-run flow: welcome, Accessibility permission, Hyper key, Slate config, done.
struct OnboardingView: View {
  @Bindable var model: AppModel
  @State private var step: OnboardingStep
  @State private var forward = true
  var openSettings: (() -> Void)?
  var onFinish: () -> Void

  init(
    model: AppModel, initialStep: OnboardingStep = .welcome, openSettings: (() -> Void)? = nil,
    onFinish: @escaping () -> Void
  ) {
    self.model = model
    self._step = State(initialValue: initialStep)
    self.openSettings = openSettings
    self.onFinish = onFinish
  }

  var body: some View {
    VStack(spacing: 0) {
      ZStack {
        stepView
          .id(step)
          .transition(
            .asymmetric(
              insertion: .offset(x: forward ? 40 : -40).combined(with: .opacity),
              removal: .offset(x: forward ? -40 : 40).combined(with: .opacity)))
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .padding(.horizontal, 48)
      .padding(.top, 36)
      footer
    }
    .background(OnboardingBackdrop())
    .environment(model)
    .tint(Theme.accent)
    .frame(width: SlatedUI.onboardingWindowSize.width, height: SlatedUI.onboardingWindowSize.height)
  }

  @ViewBuilder private var stepView: some View {
    switch step {
    case .welcome: WelcomeStep()
    case .accessibility: AccessibilityStep()
    case .hyperKey: HyperKeyStep()
    case .slateConfig: SlateConfigStep()
    case .done: DoneStep()
    }
  }

  private var footer: some View {
    // Equal flexible sides keep the progress dots centered whatever the button titles are.
    HStack(spacing: 12) {
      Group {
        if step != .welcome && step != .done {
          Button("Back") { go(-1) }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .keyboardShortcut(.cancelAction)
        } else if step == .done, let openSettings {
          Button("Open Settings") {
            openSettings()
            onFinish()
          }
          .buttonStyle(.softLarge)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      ProgressDots(step: step)
      Button(primaryTitle) {
        if step == .done { onFinish() } else { go(1) }
      }
      .buttonStyle(.gradientLarge)
      .keyboardShortcut(.defaultAction)
      .frame(maxWidth: .infinity, alignment: .trailing)
    }
    .padding(.horizontal, 28)
    .padding(.vertical, 20)
  }

  private var primaryTitle: String {
    switch step {
    case .welcome: return "Get Started"
    case .accessibility: return model.runtimeStatus.accessibilityGranted ? "Continue" : "Skip for Now"
    case .hyperKey, .slateConfig: return "Continue"
    case .done: return "Start Using Slated"
    }
  }

  private func go(_ delta: Int) {
    guard let next = OnboardingStep(rawValue: step.rawValue + delta) else { return }
    forward = delta > 0
    withAnimation(Theme.spring) { step = next }
  }
}

private struct ProgressDots: View {
  let step: OnboardingStep

  var body: some View {
    HStack(spacing: 6) {
      ForEach(OnboardingStep.allCases, id: \.self) { item in
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
    .accessibilityLabel("Step \(step.rawValue + 1) of \(OnboardingStep.allCases.count)")
  }
}

/// Soft accent light behind the onboarding content.
private struct OnboardingBackdrop: View {
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
