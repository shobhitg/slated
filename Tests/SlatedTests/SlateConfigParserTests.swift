import Foundation

@testable import SlatedCore

private let home = "/Users/tester"

/// Parses `text` with an in-memory file system.
private func parse(_ text: String, path: String? = "\(home)/.slate", files: [String: String] = [:]) -> SlateConfigFile {
  SlateConfigParser.parse(text, path: path, homeDirectory: home) { files[$0] }
}

private func errors(_ file: SlateConfigFile) -> [Diagnostic] { file.diagnostics.filter { $0.severity == .error } }
private func warnings(_ file: SlateConfigFile) -> [Diagnostic] { file.diagnostics.filter { $0.severity == .warning } }

private let hyper: Modifiers = .hyper

let slateConfigParserTests = Suite(
  "SlateConfigParser",
  [
    (
      "parses a typical config",
      {
        let file = parse(
          """
          # Window management
          config defaultToCurrentScreen true
          config nudgePercentOf screenSize
          config secondsBetweenRepeat 0.1

          bind right:alt       resize +10% +0
          bind left:ctrl;alt   resize +10% +0 bottom-right
          bind up:ctrl;cmd     push up    bar-resize:screenSizeY/2
          bind 1:ctrl;alt      throw 0 resize
          bind down:ctrl;alt;cmd  throw down  resize
          bind up:cmd;alt      focus behind
          bind esc:cmd hint
          """)
        expectEqual(file.diagnostics, [])
        expectEqual(file.settings["defaultToCurrentScreen"], .bool(true))
        expectEqual(file.settings["nudgePercentOf"], .string("screenSize"))
        expectEqual(file.settings["secondsBetweenRepeat"], .number(0.1))
        expectEqual(file.bindings.count, 7)
        expectEqual(file.bindings[0].keys, KeyCombo(key: "right", modifiers: .option))
        expectEqual(file.bindings[0].action, .resize(width: "+10%", height: "+0", anchor: .topLeft))
        expectEqual(file.bindings[1].keys, KeyCombo(key: "left", modifiers: [.control, .option]))
        expectEqual(file.bindings[1].action, .resize(width: "+10%", height: "+0", anchor: .bottomRight))
        expectEqual(file.bindings[2].action, .push(direction: .up, style: .barResize("screenSizeY/2"), screen: nil))
        expectEqual(
          file.bindings[4].action, .throwWindow(screen: .relative(.down), width: "screenSizeX", height: "screenSizeY"))
        expectEqual(file.bindings[6].action, .hint(characters: nil))
        expect(file.bindings.allSatisfy { $0.repeats == nil && $0.enabled && $0.modal == nil })
      }
    ),
    (
      "binding ids are stable across reloads and unrelated edits",
      {
        let text = "bind a:ctrl push up\nbind b:ctrl push down\nbind a:ctrl push up"
        let first = parse(text)
        expectEqual(parse(text), first)  // same file, same result
        let ids = first.bindings.map(\.id)
        expectEqual(Set(ids).count, 3)  // a duplicate line still gets its own id
        // Inserting a comment and spacing differently keeps the ids; changing an operation changes only its own.
        let edited = parse("# new comment\nbind a:ctrl  push up\nbind b:ctrl push left\nbind a:ctrl push up")
        expectEqual(edited.bindings[0].id, ids[0])
        expect(edited.bindings[1].id != ids[1])
        expectEqual(edited.bindings[2].id, ids[2])
        // The same binding in another file is a different binding.
        expect(parse(text, path: "\(home)/other.slate").bindings[0].id != ids[0])
      }
    ),
    (
      "parses modal bindings",
      {
        let file = parse(
          """
          bind 1:f4,ctrl,alt push left bar
          bind 2:ctrl,f4:toggle push right bar
          """)
        expectEqual(file.diagnostics, [])
        expectEqual(file.bindings[0].keys, KeyCombo(key: "1"))
        expectEqual(file.bindings[0].modal, ModalKey(keys: KeyCombo(key: "f4", modifiers: [.control, .option])))
        expectEqual(file.bindings[1].modal, ModalKey(keys: KeyCombo(key: "f4", modifiers: .control), toggle: true))
      }
    ),
    (
      "substitutes aliases, including inside other aliases",
      {
        let file = parse(
          """
          alias hyper ctrl;shift;alt;cmd
          alias half screenSizeX/2
          alias left-half move screenOriginX;screenOriginY ${half};screenSizeY
          alias bot-right-2nd-mon move screenOriginX+2*screenSizeX/3;screenOriginY+screenSizeY/2 screenSizeX/3;screenSizeY/2 1
          bind a:${hyper} ${left-half}
          bind b:${hyper} ${bot-right-2nd-mon}
          bind c:${hyper} push left bar-resize:${half}
          bind d:${hyper} ${undefined}
          bind e:${hyper} ${lft-half}
          """)
        expectEqual(file.bindings.count, 3)
        expectEqual(file.bindings[0].keys, KeyCombo(key: "a", modifiers: hyper))
        expectEqual(
          file.bindings[0].action,
          .move(x: "screenOriginX", y: "screenOriginY", width: "screenSizeX/2", height: "screenSizeY", screen: nil))
        expectEqual(
          file.bindings[1].action,
          .move(
            x: "screenOriginX+2*screenSizeX/3", y: "screenOriginY+screenSizeY/2", width: "screenSizeX/3",
            height: "screenSizeY/2", screen: .index(1)))
        expectEqual(file.bindings[2].action, .push(direction: .left, style: .barResize("screenSizeX/2"), screen: nil))
        let problems = errors(file)
        expectEqual(problems.map(\.line), [8, 9])
        try requireCount(problems, 2)
        expectMessage(problems[0].message, contains: "Unknown alias \"${undefined}\"")
        expectMessage(problems[1].message, contains: "did you mean \"${left-half}\"?")
      }
    ),
    (
      "an alias must be defined before it is used",
      {
        let file = parse(
          """
          bind a:ctrl ${full}
          alias full move screenOriginX;screenOriginY screenSizeX;screenSizeY
          bind b:ctrl ${full}
          """)
        expectEqual(file.bindings.map(\.keys.key), ["b"])
        expectEqual(errors(file).map(\.line), [1])
      }
    ),
    (
      "parses layouts with options, BEFORE/AFTER, and merges lines with the same name",
      {
        let file = parse(
          """
          layout myLayout 'iTerm' push up bar-resize:screenSizeY/2 | push down bar-resize:screenSizeY/2
          layout myLayout 'Google Chrome':IGNORE_FAIL,REPEAT push left bar-resize:screenSizeX/2|push right bar-resize:screenSizeX/2
          layout myLayout BEFORE shell path:~/ '/opt/local/bin/mvim before'
          layout myLayout AFTER shell path:~/ '/opt/local/bin/mvim after'
          layout myLayout BEFORE undo
          layout other 'Mail':MAIN_FIRST,SORT_TITLE,TITLE_ORDER=Inbox;Drafts,TITLE_ORDER_REGEX='^Re: .*;^Fwd' corner top-left
          layout other Safari:REPEAT_LAST,MAIN_LAST throw 1 resize
          """)
        expectEqual(file.diagnostics, [])
        expectEqual(file.layouts.map(\.name), ["myLayout", "other"])
        let layout = file.layouts[0]
        expectEqual(layout.apps.map(\.app), ["iTerm", "Google Chrome"])
        expectEqual(
          layout.apps[0].operations,
          [
            .push(direction: .up, style: .barResize("screenSizeY/2"), screen: nil),
            .push(direction: .down, style: .barResize("screenSizeY/2"), screen: nil),
          ])
        expectEqual(layout.apps[0].options, LayoutAppOptions())
        expect(layout.apps[1].options.ignoreFail && layout.apps[1].options.repeat)
        expectEqual(layout.apps[1].operations.count, 2)
        expectEqual(
          layout.before,
          [.shell(command: "/opt/local/bin/mvim before", wait: false, path: "~/"), .undo])
        expectEqual(layout.after, [.shell(command: "/opt/local/bin/mvim after", wait: false, path: "~/")])

        let mail = file.layouts[1].apps[0]
        expect(mail.options.mainFirst && mail.options.sortTitle && !mail.options.mainLast)
        expectEqual(mail.options.titleOrder, ["Inbox", "Drafts"])
        expectEqual(mail.options.titleOrderRegex, ["^Re: .*", "^Fwd"])
        let safari = file.layouts[1].apps[1]
        expectEqual(safari.app, "Safari")
        expect(safari.options.repeatLast && safari.options.mainLast)
      }
    ),
    (
      "a later layout line for the same app replaces it and moves it last",
      {
        let file = parse(
          """
          layout l 'A' push up
          layout l 'B' push down
          layout l 'A':REPEAT push left
          """)
        expectEqual(file.layouts[0].apps.map(\.app), ["B", "A"])
        expectEqual(file.layouts[0].apps[1].operations, [.push(direction: .left, style: .none, screen: nil)])
        expect(file.layouts[0].apps[1].options.repeat)
      }
    ),
    (
      "reports layout problems",
      {
        let file = parse(
          """
          layout l 'A' push up | bogus
          layout l 'A':FLY push up
          layout l 'A'
          layout l BEFORE:REPEAT undo
          layout l 'A':TITLE_ORDER_REGEX=( push up
          layout l 'A':TITLE_ORDER push up
          layout l 'A':MAIN_FIRST,MAIN_LAST push up
          """)
        expectEqual(errors(file).map(\.line), [1, 3, 4, 5, 6])
        expectEqual(warnings(file).map(\.line), [2, 7])
        try requireCount(errors(file), 5)
        try requireCount(warnings(file), 2)
        expectMessage(warnings(file)[0].message, contains: "Unknown layout option \"FLY\"")
        expectMessage(errors(file)[3].message, contains: "Invalid regular expression \"(\"")
        expectEqual(file.layouts.first?.apps.count, 1)  // the lines with warnings still load
      }
    ),
    (
      "parses default directives",
      {
        let file = parse(
          """
          default myLayout count:2
          default myLayout2 resolutions:1440x900;1024x768;1680X1050
          default 'Big Desk' resolutions:2560x1440,1920x1080
          default broken count:zero
          default broken screens:3
          default broken
          default broken resolutions:1440by900
          """)
        expectEqual(
          file.defaults,
          [
            ScreenDefault(target: "myLayout", condition: .count(2)),
            ScreenDefault(target: "myLayout2", condition: .resolutions(["1440x900", "1024x768", "1680x1050"])),
            ScreenDefault(target: "Big Desk", condition: .resolutions(["2560x1440", "1920x1080"])),
          ])
        expectEqual(errors(file).map(\.line), [4, 5, 6, 7])
      }
    ),
    (
      "sources other files relative to the home directory",
      {
        let files = [
          "\(home)/.slate.extra":
            "alias full move screenOriginX;screenOriginY screenSizeX;screenSizeY\nbind f:ctrl ${full}",
          "\(home)/configs/more.slate": "bind m:ctrl push up\nsource ~/.slate.deeper",
          "\(home)/.slate.deeper": "bind d:ctrl push down\nbind x:ctrl nonsense",
          "/etc/slate/shared": "config orderScreensLeftToRight false",
          "\(home)/My Configs/spaced.slate": "bind s:ctrl undo",
        ]
        let file = parse(
          """
          source ~/.slate.extra
          bind g:ctrl ${full}
          source configs/more.slate
          source /etc/slate/shared
          source ~/missing.slate if_exists
          source ~/missing.slate
          source '~/My Configs/spaced.slate'
          source ~/.slate.js
          source ~/.slate.extra sometimes
          """, files: files)
        expectEqual(file.bindings.map(\.keys.key), ["f", "g", "m", "d", "s"])
        expectEqual(file.settings["orderScreensLeftToRight"], .bool(false))
        let problems = errors(file)
        try requireCount(problems, 3)
        // The bad line inside a sourced file is reported against that file.
        expectEqual(problems[0].file, "\(home)/.slate.deeper")
        expectEqual(problems[0].line, 2)
        expectEqual(problems[1].file, "\(home)/.slate")
        expectEqual(problems[1].line, 6)
        expectMessage(problems[1].message, contains: "Couldn't read \"~/missing.slate\"")
        expectEqual(problems[2].line, 9)
        expectEqual(warnings(file).map(\.line), [8])
        try requireCount(warnings(file), 1)
        expectMessage(warnings(file)[0].message, contains: "JavaScript")
      }
    ),
    (
      "guards against source loops",
      {
        let files = [
          "\(home)/a.slate": "bind a:ctrl undo\nsource b.slate",
          "\(home)/b.slate": "bind b:ctrl undo\nsource ~/a.slate\nsource ~/.slate",
        ]
        let file = parse("source a.slate\nbind c:ctrl undo", files: files)
        expectEqual(file.bindings.map(\.keys.key), ["a", "b", "c"])
        let problems = errors(file)
        try requireCount(problems, 2)
        expectMessage(problems[0].message, contains: "a.slate → b.slate → a.slate")
        expectEqual(problems[0].file, "\(home)/b.slate")
        expectEqual(problems[0].line, 2)
        expectMessage(problems[1].message, contains: ".slate → a.slate → b.slate → .slate")
      }
    ),
    (
      "strips comments except inside quotes",
      {
        let file = parse(
          """
          # a comment
             # an indented comment
          bind a:ctrl push up # trailing comment
          bind b:ctrl shell '/bin/echo #not-a-comment' # but this is
          bind ':ctrl,shift,alt,cmd move screenOriginX;screenOriginY screenSizeX/2;screenSizeY # the ' key
          bind ":ctrl push down #"
          bind c:ctrl hint ABC#DEF
          config windowHintsFontName "Helvetica Neue" # with spaces
          """)
        expectEqual(file.diagnostics, [])
        try requireCount(file.bindings, 5)
        expectEqual(file.bindings[1].action, .shell(command: "/bin/echo #not-a-comment", wait: false, path: nil))
        expectEqual(file.bindings[2].keys, KeyCombo(key: "'", modifiers: hyper))
        expectEqual(
          file.bindings[2].action,
          .move(x: "screenOriginX", y: "screenOriginY", width: "screenSizeX/2", height: "screenSizeY", screen: nil))
        expectEqual(file.bindings[3].keys, KeyCombo(key: "\"", modifiers: .control))
        expectEqual(file.bindings[4].action, .hint(characters: "ABC"))
        expectEqual(file.settings["windowHintsFontName"], .string("Helvetica Neue"))
      }
    ),
    (
      "one bad line doesn't stop the file, and line numbers are right",
      {
        let file = parse(
          "bind a:ctrl push up\r\nbind b:ctrl push sideways\r\n\r\nbnid c:ctrl push up\r\nbind d:bogus push up\r\n"
            + "bind e:ctrl\r\nconfig\r\nalias lonely\r\nbind f:ctrl push down\r\n")
        expectEqual(file.bindings.map(\.keys.key), ["a", "f"])
        let problems = errors(file)
        expectEqual(problems.map(\.line), [2, 4, 5, 6, 7, 8])
        try requireCount(problems, 6)
        expectMessage(problems[0].message, contains: "Unknown direction \"sideways\"")
        expectMessage(problems[1].message, contains: "Unknown directive \"bnid\"")
        expectMessage(problems[2].message, contains: "Unknown modifier \"bogus\"")
        expect(problems.allSatisfy { $0.file == "\(home)/.slate" })
        expectEqual(problems[0].description, ".slate, line 2: \(problems[0].message)")
      }
    ),
    (
      "warns about unknown and per-app settings",
      {
        let file = parse(
          """
          config defaultToCurentScreen true
          config snapshotTitleMatch:'iTerm' sequential
          config undoMaxStackSize 20
          """)
        expectEqual(errors(file), [])
        expectEqual(warnings(file).map(\.line), [1, 2])
        try requireCount(warnings(file), 2)
        expectMessage(warnings(file)[0].message, contains: "did you mean \"defaultToCurrentScreen\"?")
        expectEqual(file.settings["defaultToCurentScreen"], .bool(true))  // kept anyway
        expectEqual(file.settings["snapshotTitleMatch"], nil)
        expectEqual(file.settings["undoMaxStackSize"], .number(20))
      }
    ),
    (
      "parses the README's binding examples",
      {
        let file = parse(
          """
          bind pad1:ctrl move 0;0 100;100 1
          bind right:ctrl resize +10% +0
          bind up:alt,ctrl push up
          bind left:ctrl,shift nudge -100 +0
          bind pad1:alt,ctrl throw 1 resize
          bind 1:ctrl corner top-left resize:screenSizeX/2;screenSizeY/2
          bind 1:ctrl shell wait path:~/code '/opt/local/bin/mvim'
          bind 1:ctrl hide 'iTerm','Google Chrome'
          bind 1:ctrl show 'iTerm','Google Chrome'
          bind 1:ctrl toggle 'iTerm','Google Chrome'
          bind 1:ctrl chain push up | push right | push down | push left
          bind 1:ctrl sequence focus right > push left | push right
          bind 1:ctrl layout myLayout
          bind 1:ctrl focus above
          bind 1:ctrl focus 'iTerm'
          bind 1:ctrl snapshot theName save-to-disk;stack
          bind 1:ctrl delete-snapshot theName all
          bind 1:ctrl activate-snapshot theName delete
          bind 1:ctrl hint QWERTYUIOP
          bind 1:ctrl grid padding:5 1680x1050:16,9 1050x1680:9,16
          bind 1:ctrl relaunch
          bind 1:ctrl undo
          bind tab:cmd switch
          """)
        expectEqual(file.diagnostics, [])
        expectEqual(file.bindings.count, 23)
        expectEqual(file.bindings[0].keys, KeyCombo(key: "pad1", modifiers: .control))
        expectEqual(file.bindings[22].action, .switchApp)
      }
    ),
    (
      "parses Slate's bundled default.slate when it is available",
      {
        // Read from the original Slate checkout (GPL; never copied into this repo). Skipped elsewhere.
        let candidates = [
          "../slate-original/Slate/default.slate", "../../../../slate-original/Slate/default.slate",
          NSHomeDirectory() + "/src/slate-original/Slate/default.slate",
        ]
        guard let text = candidates.lazy.compactMap({ try? String(contentsOfFile: $0, encoding: .utf8) }).first else {
          return
        }
        let file = SlateConfigParser.parse(text, path: "default.slate")
        expectEqual(file.diagnostics, [])
        expectEqual(file.bindings.count, 30)
        expectEqual(file.settings["defaultToCurrentScreen"], .bool(true))
        expectEqual(file.settings["resizePercentOf"], .string("screenSize"))
      }
    ),
  ])
