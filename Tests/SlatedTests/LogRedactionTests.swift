import Foundation
import SlatedCore

/// The event log describes actions with `SlateSyntax.format(action.redactedForLog)`: it may say what
/// ran, but never the text an `insert-text` types (like hotstring replacements).
let logRedactionTests = Suite(
  "LogRedaction",
  [
    (
      "insert-text content is replaced by its length",
      {
        let action = Action.insertText("hunter2 is my password", method: .paste)
        let logged = SlateSyntax.format(action.redactedForLog)
        expectEqual(logged, "insert-text paste '(22 characters)'")
        expect(!logged.contains("hunter2"))
      }
    ),
    (
      "text nested in chains, sequences, orientation pairs and repeats is redacted too",
      {
        let secret = Action.insertText("hunter2", method: .type)
        let nested: [Action] = [
          .chain([.undo, secret]),
          .sequence([SequenceStep(.wait(0.5)), SequenceStep(secret, keepWindow: true)]),
          .byOrientation(landscape: secret, portrait: .undo),
          .autoRepeat(secret, interval: 1, mode: .toggle, times: 3, jitter: 0.1),
        ]
        for action in nested {
          let logged = SlateSyntax.format(action.redactedForLog)
          expect(!logged.contains("hunter2"), logged)
          expect(logged.contains("(7 characters)"), logged)
          expectEqual(action.redactedForLog.name, action.name)
        }
        if case .sequence(let steps) = nested[1].redactedForLog {
          expectEqual(steps.map(\.keepWindow), [false, true])
        } else {
          expect(false, "a sequence stays a sequence")
        }
      }
    ),
    (
      "everything else is logged as it is",
      {
        let actions: [Action] = [
          try SlateSyntax.parseOperation("push left bar-resize:screenSizeX/2"),
          .shell(command: "/usr/bin/say done", wait: false, path: nil),
          .keystroke(KeyCombo(key: "4", modifiers: [.command, .shift])),
          .openURL("https://example.com"),
          .clipboardHistory,
        ]
        for action in actions { expectEqual(action.redactedForLog, action) }
      }
    ),
  ])
