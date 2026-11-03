import Foundation

@testable import SlatedCore

// Which copies are secrets (SecretDetection.swift): many cases each way. A false alarm only hides an
// item, but a history of dots for words, links, paths and ids would be useless, so the false cases
// matter as much. The same inputs (and more) are golden vectors for the GNOME port (fixtures/secrets.json).
// Samples are written with a § inside (SampleSecrets.unmark), so no complete token is in the repository.

/// Text that must count as a secret, with the pattern that should find it.
let secretTexts: [(String, SecretPattern)] = [
  // Private keys, alone or inside other text.
  (
    "-----BEGIN RSA PRIVATE§ KEY-----\nMIIEowIBAAKCAQEA0Z3VS5JJcds3xfn/ygWyF8PbnGy0AHB7MaGBhJbw\n-----END RSA PRIVATE§ KEY-----",
    .privateKey
  ),
  (
    "-----BEGIN OPENSSH PRIVATE§ KEY-----\nb3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQ\n-----END OPENSSH PRIVATE§ KEY-----",
    .privateKey
  ),
  (
    "-----BEGIN PRIVATE§ KEY-----\nMIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQg\n-----END PRIVATE§ KEY-----",
    .privateKey
  ),
  ("-----BEGIN EC PRIVATE§ KEY-----\nMHcCAQEEIIrYSSNQFaA2Hwf1duRSxKtLYX5CB04fSeQ6tF1aY/PuoAoGCCqGSM49\n", .privateKey),
  ("-----BEGIN ENCRYPTED PRIVATE§ KEY-----\nMIIFHDBOBgkqhkiG9w0BBQ0wQTApBgkqhkiG9w0BBQwwHAQI\n", .privateKey),
  ("-----BEGIN PGP PRIVATE§ KEY BLOCK-----\n\nlQOYBF2xJmEBCAC5\n-----END PGP PRIVATE§ KEY BLOCK-----", .privateKey),
  ("Here's the deploy key:\n-----BEGIN DSA PRIVATE§ KEY-----\nabc\n-----END DSA PRIVATE§ KEY-----", .privateKey),
  // API tokens.
  ("sk§-proj-4Fh7Kq2Lm9Np3Rs8Tv1Wx6Yz0Ab5Cd3Ef7Gh2Jk9Lm4No8Pq1Rs6Tu", .token),
  ("sk§-T3BlbkFJx7Kq2Lm9Np3Rs8Tv1Wx6Yz0Ab5Cd3Ef7Gh2Jk9Lm4No", .token),
  (
    "sk§-ant-api03-Ab3dEf5gHi7jKl9mNo1pQr3sTu5vWx7yZa9bCd1eFg3hIj5kLm7nOp9qRs1tUv3wXy5zAb7cDe9fGh1iJk3lMn5oPq7rSt9uVw-AbCdEfAA",
    .token
  ),
  ("gh§p_aB3dE5fG7hJ9kL1mN3pQ5rS7tU9vW1xY3zA5", .token),
  ("gh§o_aB3dE5fG7hJ9kL1mN3pQ5rS7tU9vW1xY3zA5", .token),
  ("gh§s_aB3dE5fG7hJ9kL1mN3pQ5rS7tU9vW1xY3zA5", .token),
  ("gi§thub_pat_11ABCDEFG0123456789_abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123", .token),
  ("gl§pat-xYz12AbC34dEf56GhI78", .token),
  ("AK§IAIOSFODNN7EXAMPLE", .token),
  ("AS§IAY34FZKBOKMUTVV7A", .token),
  ("xo§xb-1234567890123-1234567890123-AbCdEfGhIjKlMnOpQrStUvWx", .token),
  ("xo§xp-123456789012-123456789012-123456789012-0123456789abcdef0123456789abcdef", .token),
  ("xa§pp-1-A0123456789-1234567890123-0123456789abcdef0123456789abcdef", .token),
  ("sk§_live_51H8xYzAbCdEfGhIjKlMnOpQr", .token),
  ("sk§_test_4eC39HqLyjWDarjtT1zdp7dc", .token),
  ("rk§_live_51H8xYzAbCdEfGhIjKlMnOpQr", .token),
  ("wh§sec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw", .token),
  ("AI§zaSyDaGmWKa4JsXZ-HjGw7ISLn_3namBGewQe", .token),
  ("np§m_aB3dE5fG7hJ9kL1mN3pQ5rS7tU9vW1xY3zA5", .token),
  ("SG§.aB3dE5fG7hJ9kL1mN3pQ5r.aB3dE5fG7hJ9kL1mN3pQ5rS7tU9vW1xY3zA5bC7dE9fG1", .token),
  ("hf§_aB3dE5fG7hJ9kL1mN3pQ5rS7tU9vW1xY3z", .token),
  ("sh§pat_0123456789abcdef0123456789ABCDEF", .token),
  ("do§p_v1_0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", .token),
  ("AG§E-SECRET-KEY-1QQPQZRV8ZJ9NG0RU6XQ3S5Y8ZJ5C7Q2KRG3KQ0CR3UJ3ATMG4AEQS3Y3ZE", .token),
  // Tokens inside other text: shell exports, headers, JSON, .env files.
  ("export OPENAI_API_KEY=sk§-proj-4Fh7Kq2Lm9Np3Rs8Tv1Wx6Yz0Ab5Cd3Ef7Gh2Jk9Lm4No8Pq1Rs6Tu", .token),
  ("Authorization: token gh§p_aB3dE5fG7hJ9kL1mN3pQ5rS7tU9vW1xY3zA5", .token),
  ("{\"apiKey\": \"AI§zaSyDaGmWKa4JsXZ-HjGw7ISLn_3namBGewQe\"}", .token),
  ("STRIPE_KEY=sk§_test_4eC39HqLyjWDarjtT1zdp7dc\nDEBUG=true", .token),
  // JSON Web Tokens.
  (
    "ey§JhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.ey§JzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c",
    .jwt
  ),
  (
    "Bearer ey§JhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.ey§JzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U",
    .jwt
  ),
  ("ey§JhbGciOiJub25lIn0.ey§JzdWIiOiIxMjM0NTY3ODkwIn0.", .jwt),
  // Links with a password in them.
  ("postgres://admin:s3cr3tP4ss@db.example.com:5432/app", .urlPassword),
  ("https://user:hunter2@example.com/path", .urlPassword),
  ("mongodb+srv://app:Zx9!kQ@cluster0.ab1cd.mongodb.net/test?retryWrites=true", .urlPassword),
  ("redis://:p4ssw0rd@localhost:6379/0", .urlPassword),
  ("DATABASE_URL=postgres://u:p@h/db", .urlPassword),
  // Card numbers, with or without spaces or dashes.
  ("4111 1111 1111 1111", .cardNumber),
  ("4111111111111111", .cardNumber),
  ("4111-1111-1111-1111", .cardNumber),
  ("  4111 1111 1111 1111\n", .cardNumber),
  ("5555 5555 5555 4444", .cardNumber),
  ("2223 0031 2200 3222", .cardNumber),
  ("3782 822463 10005", .cardNumber),
  ("6011 1111 1111 1117", .cardNumber),
  ("3530 1113 3330 0000", .cardNumber),
  ("3056 9309 0259 04", .cardNumber),
  ("6200 0000 0000 0005", .cardNumber),
  ("4222222222222", .cardNumber),
  // Apple's suggested strong passwords.
  ("Rufvof-7qerze-hyjmuw", .generatedPassword),
  ("xhwxyp-6bunmu-ruzvoC", .generatedPassword),
  // Random-looking words: generated passwords and keys.
  ("Zq9vLm4TxB2wKp7R", .random),
  ("k3j9x!m2q8w4z7v5", .random),
  ("Tr0ub4dor&3Xq9!zLw", .random),
  ("aB3$dE5^fG7&hJ9*kL1(", .random),
  ("q8fK2xJv0ZtLm3NpR7sW1yUbA9dE4cGh", .random),
  ("8Kx2/pQ7vZ+9mLr4TnW1bYc6sHd0FgJ3eAuV5iOk", .random),
  ("p@ssW0rd!2024Secure", .random),
  ("  Zq9vLm4TxB2wKp7R  ", .random),
  // Not a token (a letter before its prefix), but random all the same.
  ("xgh§p_aB3dE5fG7hJ9kL1mN3pQ5rS7tU9vW1xY3zA5", .random),
]

/// Text that must not count as a secret (by its look; an app can still mark it).
let notSecretTexts: [String] = [
  // Words and sentences.
  "hello", "Hello, world!", "Let's sync tomorrow at 10 — I'll bring the layout sketches.",
  "Lorem ipsum dolor sit amet", "correct-horse-battery-staple", "CorrectHorseBattery9!", "Password1234567890!",
  "supercalifragilisticexpialidocious", "Antidisestablishmentarianism", "¯\\_(ツ)_/¯",
  "SELECT * FROM users WHERE id = 1",
  // Links and addresses.
  "https://github.com/shobhitg/slated", "https://example.com/path?q=1&utm_source=Newsletter2024",
  "https://user@example.com", "ssh://git@github.com:22/repo.git", "postgres://user:****@host/db",
  "postgres://user:${DB_PASSWORD}@host/db", "postgres://user:<password>@host/db", "https://user:@example.com",
  "https://example.com:8080/x", "www.example.com/Page1", "mailto:someone@example.com", "hello@example.com",
  "john.smith+tag2024@company.co.uk", "git@github.com:shobhitg/slated.git",
  // Paths and file names.
  "/Users/shobhit/src/slated/Package.swift", "~/Library/Application Support/Slated", "./build/Slated.app",
  "../x/y2/Z3.txt", "C:\\Users\\Shobhit\\Documents", "src/slated/Package.swift", "src/v2/Package2024.swift",
  "IMG_20240115_103000.jpg", "Screenshot2024-11-02at10.31.22", "Quarterly-Report-Q3-2024-FINAL-v2.xlsx",
  // Ids, hashes, colors, versions, dates.
  "550e8400-e29b-41d4-a716-446655440000", "6BA7B810-9DAD-11D1-80B4-00C04FD430C8", "#6B5EFC", "#6B5EFCAA",
  "00:1A:2B:3C:4D:5E", "da39a3ee5e6b4b0d3255bfef95601890afd80709",
  "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", "v1.2.3-beta.4+build.567", "2.0.0-rc.1",
  "1.25.3", "2024-01-15T10:30:00.000Z", "2024-01-15", "42.50", "1,234,567.89", "1730563200000",
  // Code and identifiers.
  "getUserProfileById2", "SomeVariableName_v2", "com.apple.dt.Xcode", "feature/JIRA-1234-add-login",
  "nginx:1.25.3-alpine3.18", "my-blog-post-title-2024", "screenOriginX+screenSizeX/2", "HTTPServerConfig2",
  "factorio-2.0.32-linux64", "user_name_2024!",
  // Almost tokens: short, lowercase or words after a token's prefix, or inside a longer word.
  "sk§-learn", "sk§-learn-tutorial-for-beginners-2024", "gh§p_short",
  "AK§IAIOSFODNN7EXAMPLE1", "xo§xo-gossip-girl-forever", "xo§xb-not-a-token", "sk§_live_",
  "ey§J.ey§J.x", "a.b.c", "file.tar.gz",
  // Not private keys.
  "-----BEGIN CERTIFICATE-----\nMIIDdzCCAl+gAwIBAgIEAgAAuTANBgkqhkiG9w0BAQUFADBa\n-----END CERTIFICATE-----",
  "-----BEGIN PUBLIC KEY-----\nMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE\n-----END PUBLIC KEY-----",
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl user@host",
  "BEGIN PRIVATE§ KEY",
  // Not card numbers.
  "4111 1111 1111 1112", "1234 5678 9012 3456", "4111 1111 1111 111", "4111  1111 1111 1111", "4111-1111 1111-1111",
  "978-3-16-148410-0", "+1 415 555 2671", "00000000000000", "Card: 4111 1111 1111 1111", "6011 1111 1111 1117 x",
  // Not generated passwords.
  "abcdef-ghijkl-mnopqr", "ABCDEF-123456-GHIJKL",
  // Not random enough, or not ASCII.
  "ABCD1234EFGH5678", "JBSWY3DPEHPK3PXP", "aaaaaaaaaaaaaaaaaaaaaaaa1A!", "パスワード1234567890ABCDEF",
  "Zq9vLm4TxB2wKp7", "", "   ",
]

let secretDetectionTests = Suite(
  "SecretDetection",
  [
    (
      "keys, tokens, links with passwords, cards and random passwords are secrets",
      {
        for (sample, pattern) in secretTexts {
          let text = SampleSecrets.unmark(sample)
          expect(
            SecretPatterns.match(text) == pattern,
            "\(text.debugDescription): \(String(describing: SecretPatterns.match(text)))")
        }
      }
    ),
    (
      "words, links, paths, ids, hashes, colors, versions and near misses aren't",
      {
        for sample in notSecretTexts {
          let text = SampleSecrets.unmark(sample)
          expect(
            SecretPatterns.match(text) == nil,
            "\(text.debugDescription): \(String(describing: SecretPatterns.match(text)))")
        }
      }
    ),
    (
      "marked by the app first, then a password manager, then the look (when that's on)",
      {
        let random = "Zq9vLm4TxB2wKp7R"
        func reason(_ text: String, concealed: Bool = false, app: String? = nil, patterns: Bool = true)
          -> ClipboardSecretReason?
        {
          ClipboardSecrets.reason(text: text, concealed: concealed, sourceApp: app, patterns: patterns)
        }
        expectEqual(reason("hello", concealed: true), .marked)
        expectEqual(reason(random, concealed: true, app: "com.1password.1password"), .marked)
        expectEqual(reason("hello", app: "com.1password.1password"), .app)
        expectEqual(reason("hello", app: "org.keepassxc.KeePassXC"), .app)
        expectEqual(reason(random, app: "com.bitwarden.desktop", patterns: false), .app)
        expectEqual(reason(random, app: "com.apple.Safari"), .pattern)
        expectEqual(reason(random, app: "com.apple.Safari", patterns: false), nil)
        expectEqual(reason("hello", app: "com.apple.Safari"), nil)
        expectEqual(reason("hello"), nil)
      }
    ),
    (
      "password managers by bundle id and Linux app id, in any case",
      {
        for id in [
          "com.1password.1password", "com.agilebits.onepassword7", "1password", "com.bitwarden.desktop", "bitwarden",
          "com.apple.Passwords", "com.apple.keychainaccess", "org.keepassxc.keepassxc", "org.keepassxc.KeePassXC",
          "me.proton.pass.electron", "proton-pass", "me.proton.Pass", "com.dashlane.dashlanephonefinal",
          "com.lastpass.LastPass", "org.gnome.World.Secrets", "COM.1PASSWORD.1PASSWORD",
        ] {
          expect(PasswordManagers.contains(id), id)
        }
        for id in ["com.apple.Safari", "com.google.Chrome", "1passwordx", "", "com.1password", "keepass"] {
          expect(!PasswordManagers.contains(id), id)
        }
      }
    ),
    (
      "the Luhn check and card prefixes",
      {
        expect(SecretPatterns.luhn([4, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1]))
        expect(!SecretPatterns.luhn([4, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2]))
        expect(SecretPatterns.luhn([7, 9, 9, 2, 7, 3, 9, 8, 7, 1, 3]))
        expect(!SecretPatterns.hasCardPrefix(Array(repeating: 1, count: 16)))
        expect(!SecretPatterns.hasCardPrefix([4] + Array(repeating: 1, count: 14)), "Visa has no 15-digit numbers")
        expect(SecretPatterns.hasCardPrefix([3, 4] + Array(repeating: 0, count: 13)), "Amex: 15")
      }
    ),
    (
      "entropy and word-likeness, the random rule's two measures",
      {
        let units = { (s: String) in Array(s.utf16) }
        expectEqual(SecretPatterns.entropy(units("abcdefghijklmnop")), 4)
        expectEqual(SecretPatterns.entropy(units("aaaa")), 0)
        expect(SecretPatterns.isWordLike(units("src/slated/Package.swift")))
        expect(SecretPatterns.isWordLike(units("HTTPServer")), "HTTP and Server")
        expect(!SecretPatterns.isWordLike(units("Zq9vLm4TxB2wKp7R")))
        expect(!SecretPatterns.isWordLike(units("v1.2.3-beta.4+build.567")), "under 40%: the version rule catches it")
      }
    ),
    (
      "a huge copy is searched only so far, and quickly",
      {
        let filler = String(repeating: "lorem ipsum ", count: 9_000)
        let start = Date()
        expectEqual(SecretPatterns.match(filler + SampleSecrets.unmark("gh§p_aB3dE5fG7hJ9kL1mN3pQ5rS7tU9vW1xY3zA5")), nil)
        expectEqual(SecretPatterns.match(SampleSecrets.unmark("gh§p_aB3dE5fG7hJ9kL1mN3pQ5rS7tU9vW1xY3zA5 ") + filler), .token)
        expect(Date().timeIntervalSince(start) < 2, "took \(Date().timeIntervalSince(start)) s")
      }
    ),
  ])
