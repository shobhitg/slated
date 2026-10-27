import AppKit
import Foundation

@testable import SlatedSystem

// Slated's temporary paste of a hotstring replacement (or insert-text), checked on a private pasteboard
// so the user's clipboard is never touched. Nothing is pasted: no key is pressed.

private final class Copies: @unchecked Sendable {
  var list: [PasteboardWatcher.Copy] = []
}

@MainActor private func watched(_ text: String) -> (NSPasteboard, PasteboardWatcher, Copies) {
  let pasteboard = NSPasteboard(name: NSPasteboard.Name("io.github.slated.test.\(UUID().uuidString)"))
  pasteboard.clearContents()
  pasteboard.setString(text, forType: .string)
  let watcher = PasteboardWatcher(pasteboard: pasteboard)
  let copies = Copies()
  watcher.onCopy = { copies.list.append($0) }
  return (pasteboard, watcher, copies)
}

let pasteboardTests = Suite(
  "Pasteboard",
  [
    (
      "the clipboard put back after pasting a replacement isn't recorded as a new copy",
      {
        MainActor.assumeIsolated {
          // Copied in an app clipboard history never records (Keychain Access, say).
          let (pasteboard, watcher, copies) = watched("PASSWORD-FROM-EXCLUDED-APP")
          defer { pasteboard.releaseGlobally() }
          let saved = TextInjector.stage("a long replacement", on: pasteboard)
          watcher.poll()  // while the replacement is on the clipboard
          TextInjector.restore(saved, on: pasteboard)
          watcher.poll()
          expectEqual(copies.list.count, 1)
          expect(copies.list.first?.isSlatedPaste == true, "the replacement is marked as Slated's own")
          expectEqual(pasteboard.string(forType: .string), "PASSWORD-FROM-EXCLUDED-APP")
          // The user's next copy is recorded as usual.
          pasteboard.clearContents()
          pasteboard.setString("a real copy", forType: .string)
          watcher.poll()
          expectEqual(copies.list.count, 2)
          expectEqual(copies.list.last?.text, "a real copy")
          expect(copies.list.last?.isSlatedPaste == false)
        }
      }
    ),
    (
      "a paste and its restore that both happen between two polls leave nothing to record",
      {
        MainActor.assumeIsolated {
          let (pasteboard, watcher, copies) = watched("the user's text")
          defer { pasteboard.releaseGlobally() }
          TextInjector.restore(TextInjector.stage("a long replacement", on: pasteboard), on: pasteboard)
          watcher.poll()
          expectEqual(copies.list.count, 0)
          expectEqual(pasteboard.string(forType: .string), "the user's text")
        }
      }
    ),
    (
      "contract: putting the saved items back is a pasteboard change of its own",
      {
        MainActor.assumeIsolated {
          // Why the restore must be marked: the watcher can only go by changeCount.
          let (pasteboard, _, _) = watched("the user's text")
          defer { pasteboard.releaseGlobally() }
          let saved = TextInjector.stage("a long replacement", on: pasteboard)
          let during = pasteboard.changeCount
          pasteboard.clearContents()
          pasteboard.writeObjects(saved)
          expect(pasteboard.changeCount > during)
        }
      }
    ),
  ])
