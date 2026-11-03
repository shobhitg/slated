import AppKit
import Foundation

@testable import SlatedCore
@testable import SlatedUI

// Secrets in the window and the picker: masked rows, the eye, ⌥ showing the selected row, search that
// never matches a secret's text, Hide/Show Contents, the panels kept out of screen sharing, and the
// Sensitive switch with its secrets.json text, missing text and Copy Value.

private func onMain(_ body: @MainActor () throws -> Void) throws {
  try MainActor.assumeIsolated(body)
}

let uiSecretTests = Suite(
  "UISecrets",
  [
    (
      "the picker masks secrets until the eye or ⌥ shows them, and forgets that when it closes",
      {
        try onMain {
          let picker = ClipboardPickerModel(services: PreviewServices())
          picker.resetForShowing()
          let secrets = picker.results.filter(\.isSecret)
          expectEqual(secrets.count, 3)
          expect(secrets.allSatisfy(picker.isMasked), "masked at first")
          expect(picker.results.filter { !$0.isSecret }.allSatisfy { !picker.isMasked($0) })
          expect(picker.hasSecrets)
          let first = secrets[0]
          let second = secrets[1]
          // The eye shows one until the picker closes.
          picker.toggleReveal(first.id)
          expect(!picker.isMasked(first) && picker.isMasked(second))
          picker.toggleReveal(first.id)
          expect(picker.isMasked(first))
          picker.toggleReveal(first.id)
          // ⌥ shows only the selected one, while it's held.
          picker.selectedID = second.id
          picker.optionHeld = true
          expect(!picker.isMasked(second))
          picker.moveSelection(by: 1)
          expect(picker.isMasked(second), "the selection moved on")
          picker.optionHeld = false
          picker.selectedID = second.id
          expect(picker.isMasked(second))
          picker.resetForShowing()
          expect(picker.isMasked(first), "reopening hides it again")
          picker.resetForShowing(optionHeld: true)
          expect(picker.optionHeld, "⌥ already down when it opens")
        }
      }
    ),
    (
      "the picker's search never matches a secret's text, only its app's name",
      {
        try onMain {
          let picker = ClipboardPickerModel(services: PreviewServices())
          picker.resetForShowing()
          for part in ["Tr0ub4dor", "sk-proj", "4Fh7Kq2", "pAss-w0rd", "bank"] {
            picker.query = part
            expect(picker.results.allSatisfy { !$0.isSecret }, "\(part) found a secret")
          }
          picker.query = "1pass"
          expectEqual(picker.results.map(\.sourceApp), ["com.1password.1password"])
          picker.query = "terminal"
          expect(picker.results.contains { $0.isSecret && $0.sourceApp == "com.apple.Terminal" })
        }
      }
    ),
    (
      "a click on a secret's eye shows it; anywhere else on the row pastes it, real text and all",
      {
        try onMain {
          let services = PreviewServices()
          let picker = ClipboardPickerModel(services: services)
          picker.resetForShowing()
          let secret = try require(picker.results.first(where: \.isSecret))
          picker.rowMoved(secret.id, to: CGRect(x: 5, y: 100, width: 310, height: 26))
          picker.eyeMoved(secret.id, to: CGRect(x: 260, y: 104, width: 18, height: 18))
          expectEqual(picker.eye(at: CGPoint(x: 268, y: 112)), secret.id)
          expectEqual(picker.eye(at: CGPoint(x: 100, y: 112)), nil)
          expectEqual(picker.row(at: CGPoint(x: 100, y: 112)), secret.id)
          picker.eyeMoved(secret.id, to: nil)
          expectEqual(picker.eye(at: CGPoint(x: 268, y: 112)), nil)
          picker.paste(secret.id)
          expectEqual(services.pastedClipboardItems, [secret.id])
          expect(services.clipboardItems().first { $0.text == secret.text }?.isSecret == true, "still a secret")
        }
      }
    ),
    (
      "the picker and its preview are kept out of screen sharing",
      {
        try onMain {
          let model = ClipboardPickerModel(services: PreviewServices())
          expectEqual(SlatedUI.makeClipboardPickerPanel(model: model).sharingType, .none)
          expectEqual(SlatedUI.makeClipboardPreviewPanel(model: model).sharingType, .none)
        }
      }
    ),
    (
      "Settings → Clipboard: Hide and Show Contents, search by app name, the hidden count",
      {
        try onMain {
          let model = AppModel(services: PreviewServices())
          expectEqual(model.secretClipboardCount, 3)
          let plain = try require(model.clipboardItems.first { $0.isText && !$0.isSecret })
          model.hideClipboardItem(plain.id)
          expectEqual(model.clipboardItems.first { $0.id == plain.id }?.secret, .manual)
          expectEqual(model.secretClipboardCount, 4)
          expect(model.searchClipboard(String(plain.text.prefix(8))).allSatisfy { $0.id != plain.id })
          model.unhideClipboardItem(plain.id)
          expectEqual(model.clipboardItems.first { $0.id == plain.id }?.secret, nil)
          // What a password manager copied stays hidden.
          let locked = try require(model.clipboardItems.first { $0.secret == .app })
          model.unhideClipboardItem(locked.id)
          expectEqual(model.clipboardItems.first { $0.id == locked.id }?.secret, .app)
          expectEqual(model.searchClipboard("Tr0ub").count, 0)
          expect(model.searchClipboard("1password").contains { $0.id == locked.id })
        }
      }
    ),
    (
      "the Sensitive switch moves the text into secrets.json and back; edits go there",
      {
        try onMain {
          let services = PreviewServices()
          let model = AppModel(services: services)
          model.saveDelay = .zero
          let id = model.addHotstring()
          var hotstring = try require(model.hotstring(id))
          hotstring.trigger = ";pin"
          hotstring.replacement = "4242"
          model.hotstringBinding(id)?.wrappedValue = hotstring
          model.setSensitive(true, hotstring: id)
          let name = try require(model.hotstring(id)?.secret)
          expectEqual(name, "pin")
          expectEqual(model.hotstring(id)?.replacement, "")
          expectEqual(model.secretText(of: id), "4242")
          model.setSecretText("9999", hotstring: id)
          expectEqual(model.configuration.secrets[name], "9999")
          model.saveNow()
          expectEqual(services.configuration.secrets[name], "9999")
          expect(!String(decoding: try services.configuration.encodedConfigFile(), as: UTF8.self).contains("9999"))
          // Copy Value on the replacement copies the reference, never the text.
          let index = try require(model.configuration.hotstrings.firstIndex { $0.id == id })
          let key = ConfigKeys.hotstring(at: index, in: model.configuration).appending(ConfigKeys.Hotstring.replacement)
          model.copyConfigValue(key)
          expectEqual(services.copiedTexts.last, "{\n  \"secret\" : \"pin\"\n}")
          model.copyConfigValue(ConfigKeys.secret(named: name))
          expectEqual(services.copiedTexts.count, 1)
          expectEqual(ConfigKeys.secret(named: name).display, "secrets.json › pin")
          model.setSensitive(false, hotstring: id)
          expectEqual(model.hotstring(id)?.replacement, "9999")
          expectEqual(model.configuration.secrets[name], nil)
        }
      }
    ),
    (
      "Duplicate gives a copy its own secret; Delete forgets one no hotstring uses",
      {
        try onMain {
          let model = AppModel(services: PreviewServices())
          let wifi = try require(model.configuration.hotstrings.first { $0.trigger == ";wifi" })
          model.duplicateHotstring(wifi.id)
          let copy = try require(model.configuration.hotstrings.first { $0.trigger == ";wifi2" })
          expect(copy.secret != nil && copy.secret != wifi.secret)
          expectEqual(model.secretText(of: copy.id), model.secretText(of: wifi.id))
          model.deleteHotstring(copy.id)
          expectEqual(model.configuration.secrets[copy.secret ?? ""], nil)
          expect(model.configuration.secrets[wifi.secret ?? ""] != nil)
        }
      }
    ),
    (
      "a secret missing on this computer: a warning, not an error; Overview asks for it; typing it fixes it",
      {
        try onMain {
          let services = PreviewServices()
          var config = services.configuration
          config.hotstrings.append(Hotstring(trigger: ";bank", replacement: "", secret: "bank"))
          try services.saveConfiguration(config)
          let model = AppModel(services: services)
          let bank = try require(model.configuration.hotstrings.first { $0.trigger == ";bank" })
          let issues = model.issues(for: .hotstring(bank.id))
          expect(
            issues.contains { $0.severity == .warning && $0.message.contains("isn't on this computer") }, "\(issues)")
          expect(!issues.contains { $0.severity == .error })
          expectEqual(model.state(for: bank), .missingText)
          expectEqual(model.missingSecretCount, 1)
          model.selectedPane = .overview
          model.reviewMissingSecrets()
          expectEqual(model.selectedPane, .hotstrings)
          expectEqual(model.selectedHotstringID, bank.id)
          model.setSecretText("123456", hotstring: bank.id)
          expectEqual(model.missingSecretCount, 0)
          expect(model.state(for: bank) != .missingText)
        }
      }
    ),
    (
      "a held-back hotstring keeps the secret its saved version refers to",
      {
        try onMain {
          var saved = SlatedConfiguration()
          saved.hotstrings = [Hotstring(trigger: ";pw", replacement: "", secret: "pw")]
          saved.secrets = ["pw": "hunter2"]
          var draft = saved
          draft.makeNotSensitive(hotstringAt: 0)
          draft.hotstrings[0].trigger = ""  // an error: held back
          let issues = ConfigValidator.validate(draft, knownLayouts: [])
          let output = ConfigValidator.savable(draft, lastSaved: saved, issues: issues)
          expectEqual(output.hotstrings, saved.hotstrings)
          expectEqual(output.secrets, ["pw": "hunter2"])
        }
      }
    ),
  ])
