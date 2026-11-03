import Foundation

@testable import SlatedCore

private func uuid(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))! }

// fixtures/secrets.json: which copies are secrets (SecretDetection.swift), and sensitive hotstrings'
// names and Sensitive switch (Secrets.swift). Inputs include every case of SecretDetectionTests.swift
// and SecretModelTests.swift, and edges for the port: Unicode, lengths at each limit, boundaries.

private let detectInputs: [String] = [
  // Private keys, alone or inside other text.
  "-----BEGIN RSA PRIVATE§ KEY-----\nMIIEowIBAAKCAQEA0Z3VS5JJcds3xfn/ygWyF8PbnGy0AHB7MaGBhJbw\n-----END RSA PRIVATE§ KEY-----",
  "-----BEGIN OPENSSH PRIVATE§ KEY-----\nb3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQ\n-----END OPENSSH PRIVATE§ KEY-----",
  "-----BEGIN PRIVATE§ KEY-----\nMIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQg\n-----END PRIVATE§ KEY-----",
  "-----BEGIN EC PRIVATE§ KEY-----\nMHcCAQEEIIrYSSNQFaA2Hwf1duRSxKtLYX5CB04fSeQ6tF1aY/PuoAoGCCqGSM49\n",
  "-----BEGIN ENCRYPTED PRIVATE§ KEY-----\nMIIFHDBOBgkqhkiG9w0BBQ0wQTApBgkqhkiG9w0BBQwwHAQI\n",
  "-----BEGIN PGP PRIVATE§ KEY BLOCK-----\n\nlQOYBF2xJmEBCAC5\n-----END PGP PRIVATE§ KEY BLOCK-----",
  "Here's the deploy key:\n-----BEGIN DSA PRIVATE§ KEY-----\nabc\n-----END DSA PRIVATE§ KEY-----",
  "-----BEGIN PRIVATE§ KEY----", "-----BEGIN private key-----", "-----BEGIN  PRIVATE§ KEY-----",
  "-----BEGIN " + String(repeating: "A", count: 30) + " PRIVATE§ KEY-----",
  "-----BEGIN " + String(repeating: "A", count: 40) + " PRIVATE§ KEY-----",
  "-----BEGIN PRIVATE§ KEYS-----", "-----BEGIN X PRIVATE§ KEY BLOCKS-----", "-----BEGIN -----BEGIN RSA PRIVATE§ KEY-----",
  // API tokens.
  "sk§-proj-4Fh7Kq2Lm9Np3Rs8Tv1Wx6Yz0Ab5Cd3Ef7Gh2Jk9Lm4No8Pq1Rs6Tu",
  "sk§-T3BlbkFJx7Kq2Lm9Np3Rs8Tv1Wx6Yz0Ab5Cd3Ef7Gh2Jk9Lm4No",
  "sk§-ant-api03-Ab3dEf5gHi7jKl9mNo1pQr3sTu5vWx7yZa9bCd1eFg3hIj5kLm7nOp9qRs1tUv3wXy5zAb7cDe9fGh1iJk3lMn5oPq7rSt9uVw-AbCdEfAA",
  "gh§p_aB3dE5fG7hJ9kL1mN3pQ5rS7tU9vW1xY3zA5", "gh§o_aB3dE5fG7hJ9kL1mN3pQ5rS7tU9vW1xY3zA5",
  "gh§s_aB3dE5fG7hJ9kL1mN3pQ5rS7tU9vW1xY3zA5", "gh§u_aB3dE5fG7hJ9kL1mN3pQ5rS7tU9vW1xY3zA5",
  "gh§r_aB3dE5fG7hJ9kL1mN3pQ5rS7tU9vW1xY3zA5",
  "gi§thub_pat_11ABCDEFG0123456789_abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123",
  "gl§pat-xYz12AbC34dEf56GhI78", "AK§IAIOSFODNN7EXAMPLE", "AS§IAY34FZKBOKMUTVV7A",
  "xo§xb-1234567890123-1234567890123-AbCdEfGhIjKlMnOpQrStUvWx",
  "xo§xp-123456789012-123456789012-123456789012-0123456789abcdef0123456789abcdef",
  "xa§pp-1-A0123456789-1234567890123-0123456789abcdef0123456789abcdef", "xo§xe-1-abcdefghij", "xo§xs-abcdefghi1",
  "sk§_live_51H8xYzAbCdEfGhIjKlMnOpQr", "sk§_test_4eC39HqLyjWDarjtT1zdp7dc", "rk§_live_51H8xYzAbCdEfGhIjKlMnOpQr",
  "rk§_test_51H8xYzAbCdEfGhI", "wh§sec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw", "AI§zaSyDaGmWKa4JsXZ-HjGw7ISLn_3namBGewQe",
  "np§m_aB3dE5fG7hJ9kL1mN3pQ5rS7tU9vW1xY3zA5", "py§pi-AgEIcHlwaS5vcmcCJGFiY2RlZmdoLWlqa2wtbW5vcC1xcnN0LXV2d3h5ejAxMjM0",
  "SG§.aB3dE5fG7hJ9kL1mN3pQ5r.aB3dE5fG7hJ9kL1mN3pQ5rS7tU9vW1xY3zA5bC7dE9fG1", "hf§_aB3dE5fG7hJ9kL1mN3pQ5rS7tU9vW1xY3z",
  "sh§pat_0123456789abcdef0123456789ABCDEF", "sh§pss_0123456789abcdef0123456789abcdef",
  "do§p_v1_0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
  "dc§kr_pat_aB3dE5fG7hJ9kL1mN3pQ5rS", "li§n_api_aB3dE5fG7hJ9kL1mN3pQ5rS7tU9vW1xY3zA5bC7",
  "nt§n_aB3dE5fG7hJ9kL1mN3pQ5rS7tU9vW1xY3zA5bC7dE9", "se§cret_aB3dE5fG7hJ9kL1mN3pQ5rS7tU9vW1xY3zA5bC7dE9",
  "AT§ATT3xFfGF0" + String(repeating: "aB3dE5fG7h", count: 10),
  "ya§29.a0AfH6SMBx3dE5fG7hJ9kL1mN3pQ5rS7tU9vW1xY3zA5bC7",
  "AG§E-SECRET-KEY-1QQPQZRV8ZJ9NG0RU6XQ3S5Y8ZJ5C7Q2KRG3KQ0CR3UJ3ATMG4AEQS3Y3ZE",
  "sq§0atp-aB3dE5fG7hJ9kL1mN3pQ5r", "sq§0csp-aB3dE5fG7hJ9kL1mN3pQ5rS7tU9vW1xY3zA5bC7dE",
  // Tokens inside other text.
  "export OPENAI_API_KEY=sk§-proj-4Fh7Kq2Lm9Np3Rs8Tv1Wx6Yz0Ab5Cd3Ef7Gh2Jk9Lm4No8Pq1Rs6Tu",
  "Authorization: token gh§p_aB3dE5fG7hJ9kL1mN3pQ5rS7tU9vW1xY3zA5",
  "{\"apiKey\": \"AI§zaSyDaGmWKa4JsXZ-HjGw7ISLn_3namBGewQe\"}",
  "STRIPE_KEY=sk§_test_4eC39HqLyjWDarjtT1zdp7dc\nDEBUG=true", "(gh§p_aB3dE5fG7hJ9kL1mN3pQ5rS7tU9vW1xY3zA5)",
  "my-gh§p_aB3dE5fG7hJ9kL1mN3pQ5rS7tU9vW1xY3zA5", "é gh§p_aB3dE5fG7hJ9kL1mN3pQ5rS7tU9vW1xY3zA5",
  "日本gh§p_aB3dE5fG7hJ9kL1mN3pQ5rS7tU9vW1xY3zA5",
  // JSON Web Tokens.
  "ey§JhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.ey§JzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c",
  "Bearer ey§JhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.ey§JzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U",
  "ey§JhbGciOiJub25lIn0.ey§JzdWIiOiIxMjM0NTY3ODkwIn0.", "ey§JhbGciOiJub25lIn0.ey§JzdWIiOiIxMjM0NTY3ODkwIn0",
  "ey§JhbGciOiJub25lIn0.ey§JzdWIiOiIxMjM0NTY3ODkwIn0.sig.extra", "x.ey§JhbGciOiJub25lIn0.ey§JzdWIiOiIxMjM0NTY3ODkwIn0.s",
  "ey§JhbGciOiJub25lIn0.abJzdWIiOiIxMjM0NTY3ODkwIn0.s", "ey§JhbGciOi.ey§JzdWIiOi.",
  // Links with a password in them, and ones without.
  "postgres://admin:s3cr3tP4ss@db.example.com:5432/app", "https://user:hunter2@example.com/path",
  "mongodb+srv://app:Zx9!kQ@cluster0.ab1cd.mongodb.net/test?retryWrites=true", "redis://:p4ssw0rd@localhost:6379/0",
  "DATABASE_URL=postgres://u:p@h/db", "\"amqp://guest:guest@rabbit:5672/\"", "https://a:b@c@d.com/x",
  "postgres://user:****@host/db", "postgres://user:${DB_PASSWORD}@host/db", "postgres://user:<password>@host/db",
  "postgres://user:{pw}@host/db", "https://user:@example.com", "https://user@example.com", "https://example.com:8080/x",
  "ssh://git@github.com:22/repo.git", "://user:pw@host", "1http://user:pw@host", "https://example.com/?u=a:b@c",
  // Card numbers.
  "4111 1111 1111 1111", "4111111111111111", "4111-1111-1111-1111", "  4111 1111 1111 1111\n", "5555 5555 5555 4444",
  "2223 0031 2200 3222", "3782 822463 10005", "6011 1111 1111 1117", "3530 1113 3330 0000", "3056 9309 0259 04",
  "6200 0000 0000 0005", "4222222222222", "6759649826438453", "4111 1111 1111 1112", "1234 5678 9012 3456",
  "4111 1111 1111 111", "4111  1111 1111 1111", "4111-1111 1111-1111", "978-3-16-148410-0", "+1 415 555 2671",
  "00000000000000", "Card: 4111 1111 1111 1111", "6011 1111 1111 1117 x", "-4111 1111 1111 1111",
  "4111 1111 1111 1111-",
  "4111\t1111\t1111\t1111", "４１１１１１１１１１１１１１１１", "5105105105105100", "2720999999999996", "2721000000000004",
  // Apple's suggested passwords.
  "Rufvof-7qerze-hyjmuw", "xhwxyp-6bunmu-ruzvoC", "abcdef-ghijkl-mnopqr", "ABCDEF-123456-GHIJKL",
  "Rufvof-7qerze-hyjmu", "Rufvof_7qerze_hyjmuw", "Ruf vof-7qerze-hyjmu",
  // Random-looking words.
  "Zq9vLm4TxB2wKp7R", "k3j9x!m2q8w4z7v5", "Tr0ub4dor&3Xq9!zLw", "aB3$dE5^fG7&hJ9*kL1(",
  "q8fK2xJv0ZtLm3NpR7sW1yUbA9dE4cGh", "8Kx2/pQ7vZ+9mLr4TnW1bYc6sHd0FgJ3eAuV5iOk", "p@ssW0rd!2024Secure",
  "  Zq9vLm4TxB2wKp7R  ", "xgh§p_aB3dE5fG7hJ9kL1mN3pQ5rS7tU9vW1xY3zA5", "Zq9vLm4TxB2wKp7", "Zq9vLm4TxB2wKp7R\u{E9}",
  String(repeating: "Zq9vLm4TxB2wKp7R", count: 16), String(repeating: "Zq9vLm4TxB2wKp7R", count: 16) + "x",
  "Zq9vLm4T xB2wKp7R", "Zq9vLm4T\nxB2wKp7R",
  // Words and sentences.
  "hello", "Hello, world!", "Let's sync tomorrow at 10 — I'll bring the layout sketches.", "Lorem ipsum dolor sit amet",
  "correct-horse-battery-staple", "CorrectHorseBattery9!", "Password1234567890!", "supercalifragilisticexpialidocious",
  "Antidisestablishmentarianism", "¯\\_(ツ)_/¯", "SELECT * FROM users WHERE id = 1",
  // Links and addresses.
  "https://github.com/shobhitg/slated", "https://example.com/path?q=1&utm_source=Newsletter2024",
  "www.example.com/Page1", "WWW.Example.com/Page12345", "mailto:someone@example.com", "hello@example.com",
  "john.smith+tag2024@company.co.uk", "git@github.com:shobhitg/slated.git", "a@b", "x9Kq2@Lm4T.xB2wKp7R",
  // Paths and file names.
  "/Users/shobhit/src/slated/Package.swift", "~/Library/Application Support/Slated", "./build/Slated.app",
  "../x/y2/Z3.txt", "C:\\Users\\Shobhit\\Documents", "src/slated/Package.swift", "src/v2/Package2024.swift",
  "IMG_20240115_103000.jpg", "Screenshot2024-11-02at10.31.22", "Quarterly-Report-Q3-2024-FINAL-v2.xlsx",
  "d:\\Zq9vLm4TxB2wKp7R", "Zq9vLm4\\TxB2wKp7R",
  // Ids, hashes, colors, versions, dates.
  "550e8400-e29b-41d4-a716-446655440000", "6BA7B810-9DAD-11D1-80B4-00C04FD430C8", "#6B5EFC", "#6B5EFCAA",
  "00:1A:2B:3C:4D:5E", "da39a3ee5e6b4b0d3255bfef95601890afd80709",
  "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", "v1.2.3-beta.4+build.567", "2.0.0-rc.1",
  "1.25.3", "V10.0.1-Zq9vLm4TxB2wKp7R", "2024-01-15T10:30:00.000Z", "2024-01-15", "42.50", "1,234,567.89",
  "1730563200000",
  // Code and identifiers.
  "getUserProfileById2", "SomeVariableName_v2", "com.apple.dt.Xcode", "feature/JIRA-1234-add-login",
  "nginx:1.25.3-alpine3.18", "my-blog-post-title-2024", "screenOriginX+screenSizeX/2", "HTTPServerConfig2",
  "factorio-2.0.32-linux64", "user_name_2024!", "XMLHTTPRequest2Handler", "ABCDEFGHijkl1234mnop",
  // Near misses.
  "sk§-learn", "sk§-learn-tutorial-for-beginners-2024", "gh§p_short", "AK§IAIOSFODNN7EXAMPLE1", "xo§xo-gossip-girl-forever",
  "xo§xb-not-a-token", "sk§_live_", "ey§J.ey§J.x", "a.b.c", "file.tar.gz", "AI§zaSyDaGmWKa4JsXZ-HjGw7ISLn_3namBGewQ",
  "gh§p_aB3dE5fG7hJ9kL1mN3pQ5rS7tU9vW1xY3zA5x", "gh§p_aB3dE5fG7hJ9kL1mN3pQ5rS7tU9vW1xY3zA5-",
  "gh§p_aB3dE5fG7hJ9kL1mN3pQ5rS7tU9vW1xY3zA5_tail", "sk§-ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefgh",
  "hf§_abcdefghijklmnopqrstuvwxyzabcdefgh",
  "nt§n_abcdefghijklmnopqrstuvwxyzabcdefghijklmnop", "sh§pat_0123456789abcdef0123456789abcdeg",
  // Not private keys.
  "-----BEGIN CERTIFICATE-----\nMIIDdzCCAl+gAwIBAgIEAgAAuTANBgkqhkiG9w0BAQUFADBa\n-----END CERTIFICATE-----",
  "-----BEGIN PUBLIC KEY-----\nMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE\n-----END PUBLIC KEY-----",
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl user@host", "BEGIN PRIVATE§ KEY",
  // Not random enough, not ASCII, or empty.
  "ABCD1234EFGH5678", "JBSWY3DPEHPK3PXP", "aaaaaaaaaaaaaaaaaaaaaaaa1A!", "パスワード1234567890ABCDEF", "", "   ",
  "\u{00A0}Zq9vLm4TxB2wKp7R\u{00A0}", "Zq9vLm4TxB2wKp7R\u{0}", "👍🏽Zq9vLm4TxB2wKp7R",
]

/// (text, concealed, source app, patterns on).
private let reasonInputs: [(String, Bool, String?, Bool)] = [
  ("hello", true, nil, true), ("Zq9vLm4TxB2wKp7R", true, "com.1password.1password", true),
  ("hello", false, "com.1password.1password", true), ("hello", false, "org.keepassxc.KeePassXC", true),
  ("Zq9vLm4TxB2wKp7R", false, "com.bitwarden.desktop", false), ("Zq9vLm4TxB2wKp7R", false, "com.apple.Safari", true),
  ("Zq9vLm4TxB2wKp7R", false, "com.apple.Safari", false), ("hello", false, "com.apple.Safari", true),
  ("hello", false, nil, true), ("", true, nil, false), ("", false, "1password", true), ("", false, nil, true),
  ("4111 1111 1111 1111", false, "google-chrome", true), ("hello", false, "BITWARDEN", true),
]

private let passwordManagerInputs: [String] =
  PasswordManagers.ids + [
    "COM.1PASSWORD.1PASSWORD", "org.keepassxc.KeePassXC", "Bitwarden", "com.apple.Safari", "com.google.Chrome",
    "1passwordx", "", "com.1password", "keepass", " 1password", "1password ", "org.gnome.World.secrets",
  ]

/// (trigger, names taken).
private let nameInputs: [(String, [String])] = [
  (";pw", []), (";pw", ["pw"]), (";pw", ["pw", "pw-2"]), (";pw", ["pw-2"]), ("//sig", []), (";my.pass", []), (";;", []),
  ("", []), ("", ["secret"]), (";café", []), (";cafe\u{301}", []), (";Work PW", []), (";pw_home", []), ("--x--", []),
  (";🔑key", []), ("abc;;;def", []), (String(repeating: "a", count: 50), []),
  (String(repeating: "a", count: 39) + ".bcd", []), (String(repeating: "a", count: 40) + "-", []),
  (String(repeating: "ab", count: 25), [String(repeating: "ab", count: 20)]), (";PW", ["pw"]), ("_", []),
  ("日本語", []), ("a b c", ["a-b-c", "a-b-c-2", "a-b-c-3"]), ("x\ny", []), ("\u{0}x", []),
]

/// A step of the Sensitive switch's session.
private enum SensitiveStep {
  case makeSensitive(Int)
  case makeNotSensitive(Int)
  case setText(String, Int)
  case giveOwnSecret(Int)
  case forget(String)
  case remove(Int)
  case setSecrets([String: String])
}

private struct SensitiveSession {
  var name: String
  var hotstrings: [Hotstring]
  var secrets: [String: String] = [:]
  var steps: [SensitiveStep]
}

private func hs(_ n: Int, _ trigger: String, _ replacement: String = "", secret: String? = nil) -> Hotstring {
  Hotstring(id: uuid(500 + n), trigger: trigger, replacement: replacement, secret: secret)
}

private let sensitiveSessions: [SensitiveSession] = [
  SensitiveSession(
    name: "on and off: the text moves to secrets.json under a name from the trigger, and back",
    hotstrings: [hs(1, ";pw", "hunter2"), hs(2, ";pw", "other"), hs(3, ";x", "plain")],
    steps: [
      .makeSensitive(0), .makeSensitive(1), .makeSensitive(0), .setText("new ✓\n", 0), .setText("ignored", 2),
      .makeNotSensitive(0), .makeNotSensitive(0), .makeNotSensitive(2), .makeSensitive(9), .makeNotSensitive(-1),
    ]),
  SensitiveSession(
    name: "a missing secret: no text until it's entered; off brings back an empty replacement",
    hotstrings: [hs(1, ";pw", secret: "pw"), hs(2, ";bank", secret: "bank")], secrets: ["bank": "1234"],
    steps: [.setText("typed on this computer", 0), .setSecrets([:]), .makeNotSensitive(1)]),
  SensitiveSession(
    name: "duplicates get their own secret; a secret goes when no hotstring uses it",
    hotstrings: [hs(1, ";pw", secret: "pw"), hs(2, ";pw", secret: "pw"), hs(3, ";gone", secret: "gone")],
    secrets: ["pw": "hunter2", "unused": "kept until forgotten"],
    steps: [
      .giveOwnSecret(1), .giveOwnSecret(2), .setText("changed", 1), .forget("pw"), .remove(0), .forget("pw"),
      .forget("unused"), .forget("missing"), .giveOwnSecret(5),
    ]),
  SensitiveSession(
    name: "names: a sensitive hotstring's name is taken even while its text is missing",
    hotstrings: [hs(1, ";pw", secret: "pw"), hs(2, ";pw", "two"), hs(3, ";;", "three")],
    steps: [.makeSensitive(1), .makeSensitive(2)]),
]

private func configurationJ(_ config: SlatedConfiguration) -> [String: J] {
  [
    "config": .string(String(decoding: try! config.encodedConfigFile(), as: UTF8.self)),
    "secrets": .string(String(decoding: try! config.encodedSecretsFile(), as: UTF8.self)),
    "texts": .array(config.hotstrings.map { .optional(config.text(of: $0)) }),
    "missing": .array(config.hotstrings.map { .bool(config.isMissingSecret($0)) }),
    "inUse": .array(config.secretNamesInUse.sorted().map(J.string)),
  ]
}

func secretFixtures() -> FixtureFile {
  let detect: [J] = detectInputs.map { text in
    // The text as written (a § inside, so no complete token is in the repository); the answer for it unmarked.
    ["text": .string(text), "pattern": .optional(SecretPatterns.match(SampleSecrets.unmark(text))?.rawValue)]
  }
  let reasons: [J] = reasonInputs.map { text, concealed, app, patterns in
    [
      "text": .string(text), "concealed": .bool(concealed), "app": .optional(app), "patterns": .bool(patterns),
      "reason": .optional(
        ClipboardSecrets.reason(text: text, concealed: concealed, sourceApp: app, patterns: patterns)?.rawValue),
    ]
  }
  let managers: [J] = passwordManagerInputs.map {
    ["id": .string($0), "passwordManager": .bool(PasswordManagers.contains($0))]
  }
  let names: [J] = nameInputs.map { trigger, taken in
    [
      "trigger": .string(trigger), "taken": .array(taken.map(J.string)),
      "name": .string(SlatedConfiguration.secretName(forTrigger: trigger, taken: Set(taken))),
    ]
  }
  let sessions: [J] = sensitiveSessions.map { session in
    var config = SlatedConfiguration(hotstrings: session.hotstrings, secrets: session.secrets)
    let start = configurationJ(config)
    let steps: [J] = session.steps.map { step in
      var result: [String: J]
      switch step {
      case .makeSensitive(let i):
        config.makeSensitive(hotstringAt: i)
        result = ["makeSensitive": .int(i)]
      case .makeNotSensitive(let i):
        config.makeNotSensitive(hotstringAt: i)
        result = ["makeNotSensitive": .int(i)]
      case .setText(let text, let i):
        config.setSecretText(text, forHotstringAt: i)
        result = ["setSecretText": ["text": .string(text), "index": .int(i)]]
      case .giveOwnSecret(let i):
        config.giveOwnSecret(toHotstringAt: i)
        result = ["giveOwnSecret": .int(i)]
      case .forget(let name):
        config.forgetSecret(name)
        result = ["forgetSecret": .string(name)]
      case .remove(let i):
        config.hotstrings.remove(at: i)
        result = ["removeHotstring": .int(i)]
      case .setSecrets(let secrets):
        config.secrets = secrets
        result = ["setSecrets": .object(secrets.mapValues(J.string))]
      }
      return .object(result.merging(configurationJ(config)) { a, _ in a })
    }
    return ["name": .string(session.name), "start": .object(start), "steps": .array(steps)]
  }
  let keys: [J] = ["pw", "my-pass", "a.b", "日本", "with space", "\"quoted\""].map { name in
    let key = ConfigKeys.secret(named: name)
    return ["name": .string(name), "display": .string(key.display), "path": .string(key.path)]
  }
  return FixtureFile(
    name: "secrets.json",
    description:
      "Secrets. `detect`: SecretPatterns.match (which pattern makes text look like a secret: private-key, token, jwt, "
      + "url-password anywhere in it; card-number, generated-password, random for the whole trimmed text; null for "
      + "none). `reasons`: ClipboardSecrets.reason (marked by the app, then a password manager, then the look when "
      + "`patterns` is on). `passwordManagers`: PasswordManagers.contains (case-insensitive). `names`: the name a "
      + "sensitive hotstring's secret gets from its trigger, unique among `taken`. `sessions`: the Sensitive switch "
      + "and its helpers on a configuration's hotstrings and secrets (an index out of range does nothing), with "
      + "config.json and secrets.json as Swift writes them, each hotstring's text (null while its secret is missing), "
      + "`missing`, and the names in use. `keys`: a secret's config key (`secrets.json › name`; the path keeps "
      + "`secrets.`). Hotstring ids are fixed.",
    sections: [
      "detect": detect, "reasons": reasons, "passwordManagers": managers, "names": names, "sessions": sessions,
      "keys": keys,
    ],
    depth: ["sessions": 2])
}
