import Foundation

// Sensitive hotstrings: their text lives in secrets.json (`SlatedConfiguration.secrets`), which only you
// can read, under a name; config.json says `"replacement": {"secret": "<name>"}`. The window's Sensitive
// switch moves the text in and out (`makeSensitive`, `makeNotSensitive`). Pure, so both platforms share
// the rules: the GNOME port is pinned to this file by fixtures/secrets.json.

extension SlatedConfiguration {
  /// The name a new secret gets from its hotstring's trigger: the trigger's ASCII letters, digits and
  /// underscores, anything else between them as one dash (";pw" → "pw", ";my.pass" → "my-pass"), at
  /// most 40 characters, or "secret" when that leaves nothing; then "-2", "-3"… while it's `taken`.
  public static func secretName(forTrigger trigger: String, taken: Set<String>) -> String {
    var base = ""
    var gap = false
    for unit in trigger.utf16 {
      let keep = (unit >= 48 && unit <= 57) || (unit >= 65 && unit <= 90) || (unit >= 97 && unit <= 122) || unit == 95
      guard keep else {
        gap = true
        continue
      }
      if gap && !base.isEmpty { base.append("-") }
      gap = false
      base.append(Character(Unicode.Scalar(unit)!))
    }
    base = String(base.prefix(40))
    while base.hasSuffix("-") { base.removeLast() }
    if base.isEmpty { base = "secret" }
    var name = base
    var suffix = 2
    while taken.contains(name) {
      name = "\(base)-\(suffix)"
      suffix += 1
    }
    return name
  }

  /// Every secret name in use: secrets.json's, and those hotstrings refer to (even ones missing there).
  public var secretNamesInUse: Set<String> { Set(secrets.keys).union(hotstrings.compactMap(\.secret)) }

  /// The text `hotstring` types: its secret for a sensitive one (nil while secrets.json doesn't have it),
  /// else its replacement.
  public func text(of hotstring: Hotstring) -> String? {
    guard let name = hotstring.secret else { return hotstring.replacement }
    return secrets[name]
  }

  /// A sensitive hotstring whose text isn't on this computer (config.json was copied without
  /// secrets.json, or the name isn't in it). It doesn't expand until its text is entered.
  public func isMissingSecret(_ hotstring: Hotstring) -> Bool {
    hotstring.secret.map { secrets[$0] == nil } ?? false
  }

  /// The sensitive hotstrings whose text isn't on this computer.
  public var hotstringsMissingSecrets: [Hotstring] { hotstrings.filter(isMissingSecret) }

  /// The Sensitive switch, on: the hotstring's text moves to secrets.json under a new name
  /// (`secretName`), and config.json refers to it. A hotstring already sensitive stays as it is.
  public mutating func makeSensitive(hotstringAt index: Int) {
    guard hotstrings.indices.contains(index), hotstrings[index].secret == nil else { return }
    let name = Self.secretName(forTrigger: hotstrings[index].trigger, taken: secretNamesInUse)
    secrets[name] = hotstrings[index].replacement
    hotstrings[index].secret = name
    hotstrings[index].replacement = ""
  }

  /// The Sensitive switch, off: the text moves back into config.json (empty when it wasn't on this
  /// computer), and its secret goes, unless another hotstring uses it too.
  public mutating func makeNotSensitive(hotstringAt index: Int) {
    guard hotstrings.indices.contains(index), let name = hotstrings[index].secret else { return }
    hotstrings[index].replacement = secrets[name] ?? ""
    hotstrings[index].secret = nil
    forgetSecret(name)
  }

  /// A sensitive hotstring's new text, from the masked field or "Its text isn't on this computer yet":
  /// into secrets.json. Nothing for one that isn't sensitive.
  public mutating func setSecretText(_ text: String, forHotstringAt index: Int) {
    guard hotstrings.indices.contains(index), let name = hotstrings[index].secret else { return }
    secrets[name] = text
  }

  /// A copy of a sensitive hotstring (Duplicate) gets a secret of its own with the same text, so editing
  /// one doesn't change the other. A copy of one whose text is missing is missing its own.
  public mutating func giveOwnSecret(toHotstringAt index: Int) {
    guard hotstrings.indices.contains(index), let name = hotstrings[index].secret else { return }
    let own = Self.secretName(forTrigger: hotstrings[index].trigger, taken: secretNamesInUse)
    if let text = secrets[name] { secrets[own] = text }
    hotstrings[index].secret = own
  }

  /// Removes the secret `name` unless a hotstring still refers to it: after a hotstring is deleted in the
  /// window. Secrets added to secrets.json by hand stay until then.
  public mutating func forgetSecret(_ name: String) {
    guard !hotstrings.contains(where: { $0.secret == name }) else { return }
    secrets[name] = nil
  }
}
