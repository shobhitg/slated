import AppKit
import ApplicationServices

/// Accessibility permission: Slated needs it to move other apps' windows, to run the keyboard event
/// tap (Hyper key, hotstrings), and to type text.
public enum Permissions {
  /// Whether macOS currently trusts Slated for Accessibility.
  public static var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

  /// Shows the system prompt (macOS shows it once per app) and adds Slated to the Accessibility list
  /// in System Settings so the user only has to flip the switch.
  @discardableResult
  public static func requestAccessibility() -> Bool {
    // Same value as kAXTrustedCheckOptionPrompt, spelled out to avoid touching a mutable C global.
    AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
  }

  /// Opens System Settings → Privacy & Security → Accessibility.
  @MainActor
  public static func openAccessibilitySettings() {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
      NSWorkspace.shared.open(url)
    }
  }
}
