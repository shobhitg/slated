import AppKit
import SlatedSystem
import SwiftUI

/// A brief, unobtrusive pill near the bottom of the screen confirming what just happened.
final class ActionHUD {
  private var panel: NSPanel?
  private var hideWork: DispatchWorkItem?

  func show(_ message: String) {
    let panel = self.panel ?? makePanel()
    self.panel = panel
    let host = NSHostingView(rootView: HUDPill(message: message))
    host.frame.size = host.fittingSize
    panel.contentView = host
    let size = host.fittingSize
    let screen = NSScreen.main ?? NSScreen.screens[0]
    let visible = screen.visibleFrame
    panel.setFrame(NSRect(x: visible.midX - size.width / 2, y: visible.minY + 72, width: size.width, height: size.height), display: true)
    panel.alphaValue = 1
    panel.orderFrontRegardless()

    hideWork?.cancel()
    let work = DispatchWorkItem { [weak self] in
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.25
        self?.panel?.animator().alphaValue = 0
      }
    }
    hideWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work)
  }

  private func makePanel() -> NSPanel {
    let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.level = .statusBar
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.ignoresMouseEvents = true
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    return panel
  }
}

private struct HUDPill: View {
  let message: String

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "rectangle.split.2x2.fill")
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(
          LinearGradient(colors: [.indigo, .purple, .pink], startPoint: .topLeading, endPoint: .bottomTrailing))
      Text(message)
        .font(.system(size: 13, weight: .medium))
        .lineLimit(1)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .background(.ultraThinMaterial, in: Capsule())
    .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
    .padding(8)
  }
}
