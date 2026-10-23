import AppKit
import Security

/// Facts about this build and Mac, logged at startup, plus detection of crashed previous runs.
enum Diagnostics {
  /// Version, build number and git commit stamped into Info.plist by `scripts/bundle.sh`.
  static var build: [String: Any] {
    let info = Bundle.main.infoDictionary ?? [:]
    return [
      "version": info["CFBundleShortVersionString"] as? String ?? "dev",
      "build": info["CFBundleVersion"] as? String ?? "0",
      "commit": info["SlatedGitCommit"] as? String ?? "unknown",
      "builtAt": info["SlatedBuildDate"] as? String ?? "unknown",
    ]
  }

  static var buildDescription: String {
    let b = build
    return "\(b["version"] ?? "") (\(b["build"] ?? "")) \(b["commit"] ?? "")"
  }

  static var system: [String: Any] {
    let os = ProcessInfo.processInfo.operatingSystemVersion
    var arch = "unknown"
    #if arch(arm64)
      arch = "arm64"
    #elseif arch(x86_64)
      arch = "x86_64"
    #endif
    return [
      "macOS": "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)", "arch": arch,
      "path": Bundle.main.bundlePath, "bundleID": Bundle.main.bundleIdentifier ?? "none",
      "signing": signing, "pid": Int(ProcessInfo.processInfo.processIdentifier),
    ]
  }

  /// "Slated Dev", "Developer ID Application: …", or "ad-hoc". Ad-hoc builds lose Accessibility
  /// permission on every rebuild, so this is the first thing to check when permission "resets".
  static var signing: String {
    var code: SecCode?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return "unknown" }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return "unknown" }
    var info: CFDictionary?
    guard
      SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
      let dict = info as? [String: Any]
    else { return "unsigned" }
    if let certificates = dict[kSecCodeInfoCertificates as String] as? [SecCertificate], let leaf = certificates.first {
      var name: CFString?
      SecCertificateCopyCommonName(leaf, &name)
      return (name as String?) ?? "certificate"
    }
    if let flags = dict[kSecCodeInfoFlags as String] as? UInt32, flags & 0x2 != 0 { return "ad-hoc" }
    return "unsigned"
  }

  // MARK: Crashed previous runs

  private static var markerURL: URL {
    URL(fileURLWithPath: SlatedPaths.home).appendingPathComponent("Library/Application Support/Slated/running")
  }

  /// Call at startup. If the previous run didn't quit cleanly, logs that, with any crash reports macOS
  /// wrote since it started. Then marks this run as running.
  static func checkPreviousRun() {
    let fm = FileManager.default
    if let started = (try? fm.attributesOfItem(atPath: markerURL.path))?[.creationDate] as? Date {
      let previous = (try? String(contentsOf: markerURL, encoding: .utf8)) ?? ""
      let reports = crashReports(since: started)
      Log.record(
        "app.previous_run_crashed", level: .error,
        ["previousSession": previous.trimmingCharacters(in: .whitespacesAndNewlines), "startedAt": started.description,
         "crashReports": reports.map(\.path)])
    }
    try? fm.createDirectory(at: markerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? fm.removeItem(at: markerURL)
    try? "\(Log.session) \(buildDescription)".write(to: markerURL, atomically: true, encoding: .utf8)
  }

  /// Call on a clean quit.
  static func markCleanExit() {
    try? FileManager.default.removeItem(at: markerURL)
  }

  private static func crashReports(since date: Date) -> [URL] {
    let dir = URL(fileURLWithPath: SlatedPaths.home).appendingPathComponent("Library/Logs/DiagnosticReports")
    let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey])) ?? []
    return files.filter { url in
      guard url.lastPathComponent.hasPrefix("Slated") else { return false }
      let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
      return created >= date
    }
  }
}
