# Open questions

Decisions I made on my own while you were away, and questions only you can answer. Each has the
assumption I'm currently running with, so nothing is blocked.

## Please answer

1. **The third addition.** You mentioned three things to add on top of Slate; I counted two (Caps Lock
   → Hyper from Karabiner-Elements, hotstrings from Keyboard Maestro). What's the third?
   *Assumption:* those two only.

2. **Bundle ID and GitHub home.** I used `io.github.shobhit-aida.slated` because `gh` is logged in as
   `shobhit-aida`. Will the repo live under that account, a personal one, or an org? Changing the
   bundle ID later resets the Accessibility permission (only for you, while you're the only user).

3. **Install Xcode?** Only the Command Line Tools are installed. Everything builds without Xcode,
   but Swift Testing/XCTest aren't available, so tests run through a small harness (`make test`).
   Installing Xcode would let us use Swift Testing, SwiftUI previews, and the debugger UI, and is
   needed for a future Mac App Store version.

4. **Apple Developer Program.** Needed for notarized releases (Homebrew cask, downloads) and the Mac
   App Store. Do you have a membership? *Assumption:* not yet; local builds use a self-signed
   "Slated Dev" certificate (`make dev-cert`).

5. **Mac App Store.** You mentioned making it a Mac app later. App Store apps must be sandboxed, and
   the sandbox blocks the Hyper key (`hidutil` + event tap) and likely hotstrings. Window management
   via Accessibility is possible there (Magnet does it). *Assumption:* the direct-download app stays
   the full-featured version; a store edition, if any, would be a reduced build.

6. **Caps Lock tapped alone.** Your Karabiner rule makes Caps Lock pure Hyper. Should a quick tap on
   its own send Escape (a common Karabiner rule)? *Assumption:* no, matching your current setup; it's
   a toggle in Settings → Keyboard.

7. **Your Keyboard Maestro hotstrings.** Should Slated import them? I didn't read your Keyboard
   Maestro macros file without asking, since macros can contain private text.

8. **Spaces.** Public APIs can't move windows between Spaces. *Assumption:* public APIs only;
   Slated works within the current Space. Tell me if "throw window to Space N" matters to you.

## Decisions I made (tell me if you disagree)

- **Config format changed from my earlier TOML recommendation to JSON** at
  `~/.config/slated/config.json`, because the settings UI has to write the file. JSON round-trips
  with Codable and no third-party parser; TOML would need one and would lose comments on save
  anyway. Hand edits may use comments and trailing commas (JSON5).
- **Your `~/.slate.js` runs as-is** (JavaScriptCore implementation of Slate's JS API), alongside
  bindings you create in the UI. No conversion needed. Classic `~/.slate` files work too.
- **The UI shows Slate-file bindings read-only** with a "Copy into Slated" option, rather than
  rewriting your JS file.
- **Slate's beta app switcher (`switch`)** is parsed but not implemented yet. It replaced Cmd-Tab
  via an event tap, which is fragile; I'd rather build a proper switcher later if you want one.
- **`~/.slate.js` gets Slate's whole JavaScript API**, plus a small built-in subset of underscore.js
  (`_`), which Slate preloaded for configs. Where Slated differs: a mistake is reported with its line
  and the rest of the file still loads (Slate showed a Quit/Skip alert); `slate.bind` only works
  while the config loads; and `repeatOnHoldOps` applies to every binding wherever it's set in the file.
- **A runaway loop in `~/.slate.js` would freeze Slated**, as it froze Slate: JavaScriptCore can only
  interrupt a script through private API. Tell me if that matters; the fix would be running scripts
  in a helper process.
