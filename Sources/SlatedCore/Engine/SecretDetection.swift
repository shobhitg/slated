import Foundation

// Which clipboard copies are secrets: kept in the history, but masked and in memory only (see
// `ClipboardHistory`). From most to least reliable: the app marked the copy secret, it came from a
// password manager, or it looks like one (`SecretPatterns`). The GNOME port (lib/core/secrets.js)
// is pinned to this file by fixtures/secrets.json.
//
// Patterns aim for few false positives: a false alarm only hides an item (one click shows it), but
// a history full of dots for ordinary words, links, paths and ids would be useless. Every rule works
// on ASCII, so Swift and JavaScript see the same characters.

/// Why a clipboard item is kept hidden: masked in every list, in memory only, forgotten after
/// `clipboard.secretMinutes` and when Slated quits.
public enum ClipboardSecretReason: String, Codable, Sendable, CaseIterable, Hashable {
  /// The app that copied it marked it secret: nspasteboard.org's ConcealedType on the Mac (password
  /// managers, browsers' Copy Password), KDE's `x-kde-passwordManagerHint` on GNOME.
  case marked
  /// Copied from a password manager (`PasswordManagers`).
  case app
  /// It looks like a secret: an API token, a private key, a card number, a random password.
  case pattern
  /// Hidden by hand ("Hide Contents").
  case manual

  /// Marked by its app or copied from a password manager: it stays hidden and in memory only, and
  /// "Show Contents" can't make it an ordinary item.
  public var isLocked: Bool { self == .marked || self == .app }

  /// Which reason wins when the same text is copied again: the more certain one.
  public static func stronger(_ a: ClipboardSecretReason?, _ b: ClipboardSecretReason?) -> ClipboardSecretReason? {
    guard let a else { return b }
    guard let b else { return a }
    return a.rank >= b.rank ? a : b
  }

  private var rank: Int {
    switch self {
    case .marked: return 4
    case .app: return 3
    case .manual: return 2
    case .pattern: return 1
    }
  }
}

/// What to do with a copy that's a secret (`clipboard.secrets`).
public enum ClipboardSecretHandling: String, Codable, Sendable, CaseIterable, Hashable {
  /// Kept in the history, shown as dots until revealed, in memory only.
  case masked
  /// Not recorded at all.
  case skip
}

/// Password managers, by macOS bundle identifier and Linux app id (the desktop file's name, a Flatpak's
/// id, or the window's class). The one list both platforms use: a copy from one of these is a secret.
public enum PasswordManagers {
  public static let ids: [String] = [
    // 1Password 8, 7 and 6 (macOS), and its Linux app.
    "com.1password.1password", "com.agilebits.onepassword7", "com.agilebits.onepassword4", "1password",
    // Bitwarden: macOS, Flatpak, the .deb's desktop file and the Snap.
    "com.bitwarden.desktop", "bitwarden", "bitwarden_bitwarden",
    // Apple Passwords (macOS 15) and its menu bar extra, Keychain Access.
    "com.apple.Passwords", "com.apple.Passwords.MenuBarExtra", "com.apple.keychainaccess",
    // KeePassXC (macOS, Linux and Flatpak), KeePass 2, MacPass, Strongbox.
    "org.keepassxc.keepassxc", "keepassxc", "keepass2", "com.hicknhacksoftware.MacPass",
    "com.markmcguill.strongbox.mac",
    // Dashlane, LastPass (Mac App Store and direct download).
    "com.dashlane.dashlanephonefinal", "com.lastpass.LastPass", "com.lastpass.lastpassmacdesktop",
    // Proton Pass: macOS, the Linux .deb and the Flatpak.
    "me.proton.pass.electron", "proton-pass", "me.proton.Pass",
    // Enpass, NordPass, Keeper.
    "in.sinew.Enpass-Desktop", "enpass", "com.nordsec.nordpass", "nordpass", "com.keepersecurity.passwordmanager",
    // GNOME's Secrets and Passwords and Keys (Seahorse).
    "org.gnome.World.Secrets", "org.gnome.seahorse.Application",
  ]

  private static let lowercased = Set(ids.map { $0.lowercased() })

  /// Whether `appID` is one of them. Case doesn't matter: KeePassXC is `org.keepassxc.keepassxc` on the
  /// Mac and `org.keepassxc.KeePassXC` on Linux.
  public static func contains(_ appID: String) -> Bool { lowercased.contains(appID.lowercased()) }
}

/// Decides whether a copy is a secret, and why.
public enum ClipboardSecrets {
  /// The reason a copy of `text` is a secret, or nil. `concealed`: the app marked it secret.
  /// `patterns`: `clipboard.secretPatterns`, whether text that looks like a secret counts.
  public static func reason(text: String, concealed: Bool, sourceApp: String?, patterns: Bool)
    -> ClipboardSecretReason?
  {
    if concealed { return .marked }
    if let sourceApp, PasswordManagers.contains(sourceApp) { return .app }
    if patterns, SecretPatterns.match(text) != nil { return .pattern }
    return nil
  }
}

/// What makes text look like a secret.
public enum SecretPattern: String, Sendable, CaseIterable, Hashable {
  /// `-----BEGIN … PRIVATE KEY-----`, anywhere in the text.
  case privateKey = "private-key"
  /// A well-known API token (`sk-…`, `ghp_…`, `AKIA…`, `xoxb-…`, `sk_live_…`), anywhere in the text.
  case token
  /// A JSON Web Token (`eyJ….eyJ….…`), anywhere in the text.
  case jwt
  /// A link with a password in it (`postgres://user:password@host`), anywhere in the text.
  case urlPassword = "url-password"
  /// The whole text is a card number: 13–19 digits (spaces or dashes allowed) with a card's prefix,
  /// passing the Luhn check.
  case cardNumber = "card-number"
  /// The whole text is a password as Apple's Passwords suggests them: `abcdef-ghijk1-mnoPqr`.
  case generatedPassword = "generated-password"
  /// The whole text is one random-looking word: 16+ characters, 3+ kinds of character, high entropy,
  /// not made of words.
  case random
}

public enum SecretPatterns {
  /// Text longer than this is searched only this far (UTF-16 units) for tokens and keys.
  static let scanLimit = 100_000

  /// What makes `text` look like a secret, or nil. The first that applies, in `SecretPattern`'s order.
  public static func match(_ text: String) -> SecretPattern? {
    let units = Array(text.utf16.prefix(scanLimit))
    if hasPrivateKey(units) { return .privateKey }
    if hasToken(units) { return .token }
    if hasJWT(units) { return .jwt }
    if hasURLPassword(units) { return .urlPassword }
    let whole = Array(text.trimmingCharacters(in: .whitespacesAndNewlines).utf16)
    if isCardNumber(whole) { return .cardNumber }
    if isGeneratedPassword(whole) { return .generatedPassword }
    if isRandom(whole) { return .random }
    return nil
  }

  // MARK: Characters (ASCII, as UTF-16 units)

  static func isUpper(_ c: UInt16) -> Bool { c >= 65 && c <= 90 }
  static func isLower(_ c: UInt16) -> Bool { c >= 97 && c <= 122 }
  static func isDigit(_ c: UInt16) -> Bool { c >= 48 && c <= 57 }
  static func isAlnum(_ c: UInt16) -> Bool { isUpper(c) || isLower(c) || isDigit(c) }
  static func isHex(_ c: UInt16) -> Bool { isDigit(c) || (c >= 65 && c <= 70) || (c >= 97 && c <= 102) }
  /// Printable ASCII other than a space.
  static func isVisible(_ c: UInt16) -> Bool { c >= 0x21 && c <= 0x7E }

  private static func units(_ s: String) -> [UInt16] { Array(s.utf16) }

  /// Whether `pattern` occurs in `text` at `index`.
  private static func occurs(_ pattern: [UInt16], in text: [UInt16], at index: Int) -> Bool {
    guard index >= 0, index + pattern.count <= text.count else { return false }
    var k = 0
    while k < pattern.count {
      if text[index + k] != pattern[k] { return false }
      k += 1
    }
    return true
  }

  /// Every index where `pattern` starts in `text`.
  private static func indices(of pattern: [UInt16], in text: [UInt16]) -> [Int] {
    guard let first = pattern.first, text.count >= pattern.count else { return [] }
    var found: [Int] = []
    var i = 0
    let last = text.count - pattern.count
    while i <= last {
      if text[i] == first && occurs(pattern, in: text, at: i) { found.append(i) }
      i += 1
    }
    return found
  }

  // MARK: Private keys

  private static let pemStart = units("-----BEGIN ")
  private static let dashes = units("-----")

  /// A PEM header: `-----BEGIN `, a label of capitals, digits and spaces (at most 40) ending in PRIVATE KEY
  /// (RSA, OPENSSH, EC, DSA, ENCRYPTED…) or PGP's PRIVATE KEY BLOCK, then `-----`.
  static func hasPrivateKey(_ text: [UInt16]) -> Bool {
    for start in indices(of: pemStart, in: text) {
      var end = start + pemStart.count
      while end < text.count, end - start - pemStart.count <= 40,
        isUpper(text[end]) || isDigit(text[end]) || text[end] == 32
      {
        end += 1
      }
      guard occurs(dashes, in: text, at: end) else { continue }
      let label = String(decoding: text[(start + pemStart.count)..<end], as: UTF16.self)
      if label.hasSuffix("PRIVATE KEY") || label.hasSuffix("PRIVATE KEY BLOCK") { return true }
    }
    return false
  }

  // MARK: Tokens

  /// The characters a token's body may have.
  enum Charset: Sendable {
    /// A–Z a–z 0–9.
    case alnum
    /// A–Z a–z 0–9 _ -.
    case urlSafe
    /// A–Z a–z 0–9 _.
    case word
    /// A–Z 0–9.
    case upperAlnum
    /// 0–9 a–f A–F.
    case hex
    /// 0–9 a–f.
    case lowerHex
    /// A–Z a–z 0–9 - (Slack's).
    case dashed
    /// A–Z a–z 0–9 _ - . (SendGrid's two parts).
    case dotted

    func contains(_ c: UInt16) -> Bool {
      switch self {
      case .alnum: return SecretPatterns.isAlnum(c)
      case .urlSafe: return SecretPatterns.isAlnum(c) || c == 95 || c == 45
      case .word: return SecretPatterns.isAlnum(c) || c == 95
      case .upperAlnum: return SecretPatterns.isUpper(c) || SecretPatterns.isDigit(c)
      case .hex: return SecretPatterns.isHex(c)
      case .lowerHex: return SecretPatterns.isDigit(c) || (c >= 97 && c <= 102)
      case .dashed: return SecretPatterns.isAlnum(c) || c == 45
      case .dotted: return SecretPatterns.isAlnum(c) || c == 95 || c == 45 || c == 46
      }
    }
  }

  /// A well-known token: `prefix`, then `min`…`max` characters of `charset`. `mixed`: the body has a
  /// lowercase letter, a capital and a digit; `digit`: a digit at least. Both keep words that happen to
  /// start like a token (`sk-learn-tutorial-for-beginners`) out.
  struct TokenRule: Sendable {
    var prefix: String
    var charset: Charset
    var min: Int
    var max: Int
    var mixed = false
    var digit = false
  }

  static let tokenRules: [TokenRule] = {
    var rules: [TokenRule] = [
      // OpenAI (sk-…, sk-proj-…) and Anthropic (sk-ant-…).
      TokenRule(prefix: "sk-", charset: .urlSafe, min: 20, max: 250, mixed: true),
      // GitHub: personal, OAuth, user-to-server, server-to-server, refresh; fine-grained.
      TokenRule(prefix: "github_pat_", charset: .word, min: 22, max: 255),
      TokenRule(prefix: "glpat-", charset: .urlSafe, min: 20, max: 64),
      TokenRule(prefix: "AKIA", charset: .upperAlnum, min: 16, max: 16),
      TokenRule(prefix: "ASIA", charset: .upperAlnum, min: 16, max: 16),
      TokenRule(prefix: "whsec_", charset: .alnum, min: 24, max: 64),
      TokenRule(prefix: "AIza", charset: .urlSafe, min: 35, max: 35),
      TokenRule(prefix: "npm_", charset: .alnum, min: 36, max: 36),
      TokenRule(prefix: "pypi-", charset: .urlSafe, min: 50, max: 255),
      TokenRule(prefix: "SG.", charset: .dotted, min: 60, max: 70),
      TokenRule(prefix: "hf_", charset: .alnum, min: 30, max: 40, mixed: true),
      TokenRule(prefix: "dckr_pat_", charset: .urlSafe, min: 20, max: 64),
      TokenRule(prefix: "dop_v1_", charset: .lowerHex, min: 64, max: 64),
      TokenRule(prefix: "lin_api_", charset: .alnum, min: 40, max: 40),
      TokenRule(prefix: "ntn_", charset: .alnum, min: 40, max: 64, digit: true),
      TokenRule(prefix: "secret_", charset: .alnum, min: 43, max: 43),
      TokenRule(prefix: "ATATT", charset: .urlSafe, min: 100, max: 300),
      TokenRule(prefix: "ya29.", charset: .urlSafe, min: 30, max: 2048),
      TokenRule(prefix: "AGE-SECRET-KEY-1", charset: .upperAlnum, min: 58, max: 58),
      TokenRule(prefix: "sq0atp-", charset: .urlSafe, min: 22, max: 64),
      TokenRule(prefix: "sq0csp-", charset: .urlSafe, min: 40, max: 64),
    ]
    for kind in ["ghp_", "gho_", "ghu_", "ghs_", "ghr_"] {
      rules.append(TokenRule(prefix: kind, charset: .alnum, min: 36, max: 36))
    }
    // Slack: bot, user, app, session, refresh, rotating; app-level tokens.
    for kind in ["xoxa-", "xoxb-", "xoxe-", "xoxp-", "xoxr-", "xoxs-", "xapp-"] {
      rules.append(TokenRule(prefix: kind, charset: .dashed, min: 10, max: 255, digit: true))
    }
    // Stripe: secret and restricted keys, live and test.
    for kind in ["sk_live_", "sk_test_", "rk_live_", "rk_test_"] {
      rules.append(TokenRule(prefix: kind, charset: .alnum, min: 16, max: 255))
    }
    // Shopify: admin, shared secret, custom and private app tokens.
    for kind in ["shpat_", "shpss_", "shpca_", "shppa_"] {
      rules.append(TokenRule(prefix: kind, charset: .hex, min: 32, max: 32))
    }
    return rules
  }()

  /// A token from `tokenRules` anywhere: after the start or a character that isn't a letter or digit,
  /// with its whole body (the characters of its charset that follow) the right length and not followed
  /// by a letter or digit.
  static func hasToken(_ text: [UInt16]) -> Bool {
    // One pass: at each start of a word, only the rules whose prefix starts with that character.
    var start = 0
    while start < text.count {
      defer { start += 1 }
      guard start == 0 || !isAlnum(text[start - 1]), let rules = rulesByFirstUnit[text[start]] else { continue }
      for (prefix, rule) in rules where occurs(prefix, in: text, at: start) {
        var end = start + prefix.count
        while end < text.count, rule.charset.contains(text[end]) { end += 1 }
        let body = text[(start + prefix.count)..<end]
        guard body.count >= rule.min, body.count <= rule.max, end == text.count || !isAlnum(text[end]) else {
          continue
        }
        if rule.mixed,
          !(body.contains(where: isLower) && body.contains(where: isUpper) && body.contains(where: isDigit))
        {
          continue
        }
        if rule.digit, !body.contains(where: isDigit) { continue }
        return true
      }
    }
    return false
  }

  /// `tokenRules` by their prefix's first character, with the prefix as UTF-16 units.
  private static let rulesByFirstUnit: [UInt16: [([UInt16], TokenRule)]] = {
    var table: [UInt16: [([UInt16], TokenRule)]] = [:]
    for rule in tokenRules {
      let prefix = units(rule.prefix)
      table[prefix[0], default: []].append((prefix, rule))
    }
    return table
  }()

  // MARK: JSON Web Tokens

  private static let jwtStart = units("eyJ")

  /// `header.payload.signature`, base64url: the header and payload JSON objects (so starting `eyJ`) of
  /// 10+ characters each, the signature possibly empty. Not inside a longer word or a dotted name.
  static func hasJWT(_ text: [UInt16]) -> Bool {
    func isPart(_ c: UInt16) -> Bool { isAlnum(c) || c == 95 || c == 45 }
    for start in indices(of: jwtStart, in: text) where start == 0 || !(isPart(text[start - 1]) || text[start - 1] == 46)
    {
      var end = start
      while end < text.count, isPart(text[end]) || text[end] == 46 { end += 1 }
      let parts = text[start..<end].split(separator: 46, omittingEmptySubsequences: false)
      guard parts.count == 3 else { continue }
      let header = Array(parts[0])
      let payload = Array(parts[1])
      if header.count >= 10, payload.count >= 10, occurs(jwtStart, in: payload, at: 0) { return true }
    }
    return false
  }

  // MARK: Links with a password

  private static let schemeSeparator = units("://")

  /// `scheme://user:password@host…` with a password that isn't a placeholder (`*****`, `$PASSWORD`,
  /// `<password>`, `{password}`).
  static func hasURLPassword(_ text: [UInt16]) -> Bool {
    for index in indices(of: schemeSeparator, in: text) {
      var schemeStart = index
      while schemeStart > 0, isAlnum(text[schemeStart - 1]) || [43, 45, 46].contains(text[schemeStart - 1]) {
        schemeStart -= 1
      }
      guard schemeStart < index, isUpper(text[schemeStart]) || isLower(text[schemeStart]) else { continue }
      var end = index + schemeSeparator.count
      // The authority: up to a path, query or fragment, or anything that can't be in a link.
      while end < text.count, isVisible(text[end]), ![47, 63, 35, 34, 39, 60, 62, 96].contains(text[end]) { end += 1 }
      let authority = Array(text[(index + schemeSeparator.count)..<end])
      guard let at = authority.lastIndex(of: 64) else { continue }
      let userinfo = authority[..<at]
      guard let colon = userinfo.firstIndex(of: 58) else { continue }
      let password = userinfo[(colon + 1)...]
      guard let first = password.first, ![42, 36, 60, 123].contains(first) else { continue }
      return true
    }
    return false
  }

  // MARK: Card numbers

  /// 13–19 digits, in groups separated by single spaces or single dashes (one kind), with the prefix
  /// and length of a card network and a valid Luhn check digit.
  static func isCardNumber(_ text: [UInt16]) -> Bool {
    guard let first = text.first, let last = text.last, isDigit(first), isDigit(last) else { return false }
    var digits: [Int] = []
    var separator: UInt16?
    var previousWasSeparator = false
    for c in text {
      if isDigit(c) {
        digits.append(Int(c) - 48)
        previousWasSeparator = false
      } else if c == 32 || c == 45 {
        if previousWasSeparator || (separator != nil && separator != c) { return false }
        separator = c
        previousWasSeparator = true
      } else {
        return false
      }
    }
    guard (13...19).contains(digits.count), hasCardPrefix(digits) else { return false }
    return luhn(digits)
  }

  /// Whether the number starts like a card of a network that issues that length.
  static func hasCardPrefix(_ digits: [Int]) -> Bool {
    func prefix(_ n: Int) -> Int { digits.prefix(n).reduce(0) { $0 * 10 + $1 } }
    let length = digits.count
    let p2 = prefix(2)
    let p3 = prefix(3)
    let p4 = prefix(4)
    // Visa.
    if digits[0] == 4 { return [13, 16, 19].contains(length) }
    // Mastercard.
    if (51...55).contains(p2) || (2221...2720).contains(p4) { return length == 16 }
    // American Express.
    if p2 == 34 || p2 == 37 { return length == 15 }
    // Discover, JCB, UnionPay.
    if p4 == 6011 || p2 == 65 || (644...649).contains(p3) || (3528...3589).contains(p4) || p2 == 62 {
      return (16...19).contains(length)
    }
    // Diners Club.
    if (300...305).contains(p3) || p2 == 36 || p2 == 38 || p2 == 39 { return (14...19).contains(length) }
    // Maestro.
    if p2 == 50 || (56...69).contains(p2) { return (13...19).contains(length) }
    return false
  }

  /// The Luhn check: doubling every second digit from the right, the digits' sum ends in 0.
  static func luhn(_ digits: [Int]) -> Bool {
    var sum = 0
    for (i, digit) in digits.reversed().enumerated() {
      if i % 2 == 1 {
        let doubled = digit * 2
        sum += doubled > 9 ? doubled - 9 : doubled
      } else {
        sum += digit
      }
    }
    return sum % 10 == 0
  }

  // MARK: Generated passwords

  /// Apple's suggested strong passwords: three groups of six letters and digits joined by dashes, with
  /// a lowercase letter, a capital and a digit.
  static func isGeneratedPassword(_ text: [UInt16]) -> Bool {
    guard text.count == 20, text[6] == 45, text[13] == 45 else { return false }
    let groups = [text[0..<6], text[7..<13], text[14..<20]]
    guard groups.allSatisfy({ $0.allSatisfy(isAlnum) }) else { return false }
    return text.contains(where: isLower) && text.contains(where: isUpper) && text.contains(where: isDigit)
  }

  // MARK: Random strings

  /// One word of 16–256 visible ASCII characters with at least three kinds of character (lowercase,
  /// capitals, digits, symbols) including a letter and a digit, Shannon entropy at least
  /// `entropyThreshold`, and less than 40% of it in words. Never a link, an email address, a path, a hex
  /// id (UUIDs, hashes, MAC addresses, colors) or a version number.
  static func isRandom(_ text: [UInt16]) -> Bool {
    let n = text.count
    guard (16...256).contains(n), text.allSatisfy(isVisible) else { return false }
    if !indices(of: schemeSeparator, in: text).isEmpty { return false }
    if looksLikeEmail(text) || looksLikePath(text) || isHexID(text) || looksLikeVersion(text) { return false }
    if text.count >= 4, String(decoding: text[0..<4], as: UTF16.self).lowercased() == "www." { return false }
    let lower = text.contains(where: isLower)
    let upper = text.contains(where: isUpper)
    let digit = text.contains(where: isDigit)
    let symbol = text.contains { !isAlnum($0) }
    let kinds = [lower, upper, digit, symbol].filter { $0 }.count
    guard kinds >= 3, lower || upper, digit else { return false }
    guard entropy(text) >= entropyThreshold(n) else { return false }
    return !isWordLike(text)
  }

  /// Bits per character a random string of `n` characters clears easily, and words, ids and dates
  /// don't: a short string can't have more than log2(n).
  static func entropyThreshold(_ n: Int) -> Double {
    if n < 20 { return 3.6 }
    if n < 28 { return 3.9 }
    if n < 40 { return 4.2 }
    return 4.4
  }

  /// Shannon entropy in bits per character. The counts are summed smallest first, so JavaScript adds
  /// them in the same order.
  static func entropy(_ text: [UInt16]) -> Double {
    var counts: [UInt16: Int] = [:]
    for c in text { counts[c, default: 0] += 1 }
    let n = Double(text.count)
    var sum = 0.0
    for count in counts.values.sorted() { sum += Double(count) * log2(Double(count)) }
    return log2(n) - sum / n
  }

  /// Whether 40% or more of the characters are in words of four letters or more: runs of lowercase
  /// letters (with a capital in front, `Package`) and runs of capitals (`JIRA`; before a lowercase run,
  /// the last capital starts the next word: `HTTPServer`).
  static func isWordLike(_ text: [UInt16]) -> Bool {
    var inWords = 0
    var i = 0
    let n = text.count
    while i < n {
      if isUpper(text[i]) {
        var j = i
        while j < n, isUpper(text[j]) { j += 1 }
        let capitals = j - i
        if j < n, isLower(text[j]) {
          if capitals - 1 >= 4 { inWords += capitals - 1 }
          var k = j
          while k < n, isLower(text[k]) { k += 1 }
          if 1 + k - j >= 4 { inWords += 1 + k - j }
          i = k
        } else {
          if capitals >= 4 { inWords += capitals }
          i = j
        }
      } else if isLower(text[i]) {
        var k = i
        while k < n, isLower(text[k]) { k += 1 }
        if k - i >= 4 { inWords += k - i }
        i = k
      } else {
        i += 1
      }
    }
    return inWords * 5 >= n * 2
  }

  /// `someone@example.com`, `git@github.com`: an `@` followed by a host name with a dot.
  static func looksLikeEmail(_ text: [UInt16]) -> Bool {
    guard let at = text.lastIndex(of: 64), at > 0 else { return false }
    let host = text[(at + 1)...]
    return host.contains(46) && host.allSatisfy { isAlnum($0) || $0 == 46 || $0 == 45 }
  }

  /// `/usr/local`, `~/Documents`, `./build`, `../x`, `C:\Users`, anything with a backslash.
  static func looksLikePath(_ text: [UInt16]) -> Bool {
    guard let first = text.first else { return false }
    if first == 47 || first == 126 || text.contains(92) { return true }
    if occurs(units("./"), in: text, at: 0) || occurs(units("../"), in: text, at: 0) { return true }
    return text.count >= 3 && (isUpper(text[0]) || isLower(text[0])) && text[1] == 58 && text[2] == 92
  }

  /// Hex digits and separators only (`-:._#`): UUIDs, hashes, MAC addresses, colors.
  static func isHexID(_ text: [UInt16]) -> Bool {
    let digits = text.filter { ![45, 58, 46, 95, 35].contains($0) }
    return !digits.isEmpty && digits.allSatisfy(isHex)
  }

  /// `1.2.3`, `v2.0.1-beta.4+build.567`: digits, a dot and digits at the start (after a `v`).
  static func looksLikeVersion(_ text: [UInt16]) -> Bool {
    var i = text.first == 118 || text.first == 86 ? 1 : 0
    let start = i
    while i < text.count, isDigit(text[i]) { i += 1 }
    guard i > start, i < text.count, text[i] == 46, i + 1 < text.count else { return false }
    return isDigit(text[i + 1])
  }
}

/// Sample secrets in tests, fixtures and previews are written with a § inside, so no complete token is in
/// the repository: GitHub's push protection (and other secret scanners) would take them for real ones.
public enum SampleSecrets {
  /// The sample as the detector should see it.
  public static func unmark(_ sample: String) -> String { sample.replacingOccurrences(of: "§", with: "") }
}
