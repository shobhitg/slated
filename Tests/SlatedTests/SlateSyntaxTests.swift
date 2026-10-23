import Foundation

@testable import SlatedCore

private func parse(_ string: String) throws -> Action { try SlateSyntax.parseOperation(string) }

private func fullScreenThrow(_ screen: ScreenRef) -> Action {
  .throwWindow(screen: screen, width: "screenSizeX", height: "screenSizeY")
}

let slateSyntaxTests = Suite(
  "SlateSyntax",
  [
    (
      "parses the operation strings in the author's .slate.js",
      {
        expectEqual(
          try parse("push top bar-resize:screenSizeY/2"),
          .push(direction: .up, style: .barResize("screenSizeY/2"), screen: nil))
        expectEqual(
          try parse("grid padding:4 0:6,6 1:6,6 2:6,6"),
          .grid(
            padding: 4,
            grids: [
              GridScreen(screen: "0", width: 6, height: 6), GridScreen(screen: "1", width: 6, height: 6),
              GridScreen(screen: "2", width: 6, height: 6),
            ]))
        expectEqual(try parse("throw right resize"), fullScreenThrow(.relative(.right)))
        expectEqual(try parse("throw left  resize"), fullScreenThrow(.relative(.left)))
        expectEqual(try parse("throw up  resize"), fullScreenThrow(.relative(.up)))
        expectEqual(try parse("throw 1  resize"), fullScreenThrow(.index(1)))
      }
    ),
    (
      "parses move, resize, push, nudge, throw and corner",
      {
        expectEqual(
          try parse("move screenOriginX;screenOriginY screenSizeX/2;screenSizeY 1"),
          .move(
            x: "screenOriginX", y: "screenOriginY", width: "screenSizeX/2", height: "screenSizeY", screen: .index(1)))
        expectEqual(try parse("move 0;0 100;100"), .move(x: "0", y: "0", width: "100", height: "100", screen: nil))
        // Slate's older comma separator, with commas inside function calls left alone.
        expectEqual(try parse("move 0,0 100,100"), .move(x: "0", y: "0", width: "100", height: "100", screen: nil))
        expectEqual(
          try parse("move max({0,1}),0 100;100"),
          .move(x: "max({0,1})", y: "0", width: "100", height: "100", screen: nil))
        expectEqual(
          try parse("move screenOriginX;screenOriginY screenSizeX;screenSizeY ordered:2"),
          .move(
            x: "screenOriginX", y: "screenOriginY", width: "screenSizeX", height: "screenSizeY",
            screen: .orderedIndex(2)))

        expectEqual(
          try parse("resize +10% -100 bottom-right"), .resize(width: "+10%", height: "-100", anchor: .bottomRight))
        expectEqual(try parse("resize +10% +0"), .resize(width: "+10%", height: "+0", anchor: .topLeft))
        expectEqual(
          try parse("resize screenSizeX/2 50%"), .resize(width: "screenSizeX/2", height: "50%", anchor: .topLeft))

        expectEqual(
          try parse("push up bar-resize:screenSizeY/2 1"),
          .push(direction: .up, style: .barResize("screenSizeY/2"), screen: .index(1)))
        expectEqual(try parse("push up"), .push(direction: .up, style: .none, screen: nil))
        expectEqual(try parse("push bottom center"), .push(direction: .down, style: .center, screen: nil))
        expectEqual(try parse("push left bar"), .push(direction: .left, style: .bar, screen: nil))
        expectEqual(try parse("push right none next"), .push(direction: .right, style: .none, screen: .next))
        expectEqual(try parse("push up 1"), .push(direction: .up, style: .none, screen: .index(1)))

        expectEqual(try parse("nudge -100 +0"), .nudge(x: "-100", y: "+0"))
        expectEqual(try parse("nudge +10% -10%"), .nudge(x: "+10%", y: "-10%"))
        expectEqual(try parse("nudge +screenSizeX/10 +0"), .nudge(x: "+screenSizeX/10", y: "+0"))

        expectEqual(
          try parse("throw 1 resize:screenSizeX/2;screenSizeY"),
          .throwWindow(screen: .index(1), width: "screenSizeX/2", height: "screenSizeY"))
        expectEqual(try parse("throw 0"), .throwWindow(screen: .index(0), width: nil, height: nil))
        expectEqual(try parse("throw next noresize"), .throwWindow(screen: .next, width: nil, height: nil))
        expectEqual(try parse("throw 1920x1080 resize"), fullScreenThrow(.resolution(width: 1920, height: 1080)))
        expectEqual(try parse("throw down resize"), fullScreenThrow(.relative(.down)))

        expectEqual(
          try parse("corner top-left resize:screenSizeX/2;screenSizeY/2"),
          .corner(.topLeft, width: "screenSizeX/2", height: "screenSizeY/2", screen: nil))
        expectEqual(try parse("corner bottom-right"), .corner(.bottomRight, width: nil, height: nil, screen: nil))
        expectEqual(
          try parse("corner top-right resize:400;300 left"),
          .corner(.topRight, width: "400", height: "300", screen: .relative(.left)))
        expectEqual(
          try parse("corner bottom-left noresize 2"), .corner(.bottomLeft, width: nil, height: nil, screen: .index(2)))
        expectEqual(try parse("corner bottom-left 2"), .corner(.bottomLeft, width: nil, height: nil, screen: .index(2)))
      }
    ),
    (
      "is whitespace-tolerant and case-insensitive about names",
      {
        expectEqual(try parse("  throw\t1   resize  "), fullScreenThrow(.index(1)))
        expectEqual(try parse("PUSH Up BAR"), .push(direction: .up, style: .bar, screen: nil))
        expectEqual(try parse("chain push up|push down"), try parse("chain push up | push down"))
        expectEqual(
          try parse("chain   push up   |   push down  "),
          .chain([.push(direction: .up, style: .none, screen: nil), .push(direction: .down, style: .none, screen: nil)])
        )
      }
    ),
    (
      "parses chain and sequence",
      {
        expectEqual(
          try parse("chain push up | push right | push down | push left"),
          .chain([
            .push(direction: .up, style: .none, screen: nil), .push(direction: .right, style: .none, screen: nil),
            .push(direction: .down, style: .none, screen: nil), .push(direction: .left, style: .none, screen: nil),
          ]))
        expectEqual(
          try parse("sequence focus right > push left | push right"),
          .sequence([
            SequenceStep(.focus(.right)),
            SequenceStep(.push(direction: .left, style: .none, screen: nil), keepWindow: true),
            SequenceStep(.push(direction: .right, style: .none, screen: nil)),
          ]))
        // A separator inside a quoted shell command doesn't split.
        expectEqual(
          try parse("sequence shell wait '/bin/sh -c \"ls | wc > /tmp/x\"' | undo"),
          .sequence([
            SequenceStep(.shell(command: "/bin/sh -c \"ls | wc > /tmp/x\"", wait: true, path: nil)),
            SequenceStep(.undo),
          ]))
      }
    ),
    (
      "parses focus, layouts, snapshots, hints, grids and the rest",
      {
        expectEqual(try parse("layout myLayout"), .layout(name: "myLayout"))
        expectEqual(try parse("layout 'My Layout'"), .layout(name: "My Layout"))
        expectEqual(try parse("focus above"), .focus(.up))
        expectEqual(try parse("focus behind"), .focus(.behind))
        expectEqual(try parse("focus 'iTerm'"), .focusApp("iTerm"))
        expectEqual(try parse("focus \"Google Chrome\""), .focusApp("Google Chrome"))
        expectEqual(try parse("focus 'left'"), .focusApp("left"))
        expectEqual(
          try parse("snapshot theName save-to-disk;stack"), .snapshot(name: "theName", save: true, stack: true))
        expectEqual(try parse("snapshot theName"), .snapshot(name: "theName", save: false, stack: false))
        expectEqual(try parse("snapshot theName stack"), .snapshot(name: "theName", save: false, stack: true))
        expectEqual(try parse("delete-snapshot theName all"), .deleteSnapshot(name: "theName", all: true))
        expectEqual(try parse("delete-snapshot theName"), .deleteSnapshot(name: "theName", all: false))
        expectEqual(try parse("activate-snapshot theName delete"), .activateSnapshot(name: "theName", delete: true))
        expectEqual(try parse("hint"), .hint(characters: nil))
        expectEqual(try parse("hint QWERTYUIOP"), .hint(characters: "QWERTYUIOP"))
        expectEqual(
          try parse("grid padding:5 1680x1050:16,9 1050x1680:9,16"),
          .grid(
            padding: 5,
            grids: [
              GridScreen(screen: "1680x1050", width: 16, height: 9),
              GridScreen(screen: "1050x1680", width: 9, height: 16),
            ]))
        expectEqual(try parse("grid"), .grid(padding: nil, grids: []))
        expectEqual(
          try parse("grid 0:4,4 0:6,6"), .grid(padding: nil, grids: [GridScreen(screen: "0", width: 6, height: 6)]))
        expectEqual(try parse("undo"), .undo)
        expectEqual(try parse("relaunch"), .relaunch)
        expectEqual(try parse("switch"), .switchApp)
        expectEqual(try parse("switch back:shift quit:q"), .switchApp)
      }
    ),
    (
      "parses hide, show and toggle app lists",
      {
        expectEqual(try parse("hide 'iTerm','Google Chrome'"), .hide(.apps(["iTerm", "Google Chrome"])))
        expectEqual(try parse("show 'iTerm', \"Google Chrome\""), .show(.apps(["iTerm", "Google Chrome"])))
        expectEqual(try parse("toggle iTerm"), .toggle(.apps(["iTerm"])))
        expectEqual(try parse("hide Google Chrome"), .hide(.apps(["Google Chrome"])))  // unquoted works, like Slate
        expectEqual(try parse("hide 'Apps, Inc.','Other'"), .hide(.apps(["Apps, Inc.", "Other"])))
        expectEqual(try parse("hide current"), .hide(.current))
        expectEqual(try parse("toggle all"), .toggle(.all))
        expectEqual(try parse("hide all-but:'iTerm'"), .hide(.allBut("iTerm")))
        expectEqual(try parse("show all-but:'Google Chrome'"), .show(.allBut("Google Chrome")))
        expectEqual(try parse("hide all-but:Finder"), .hide(.allBut("Finder")))
        expectEqual(try parse("hide 'current'"), .hide(.apps(["current"])))  // quoted means an app name
        expectThrows { _ = try parse("hide current,'iTerm'") }
        expectThrows { _ = try parse("hide 'iTerm',,'Finder'") }
        expectThrows { _ = try parse("hide") }
      }
    ),
    (
      "parses shell commands with both quote styles and nested quotes",
      {
        expectEqual(
          try parse("shell wait path:~/code '/opt/local/bin/mvim'"),
          .shell(command: "/opt/local/bin/mvim", wait: true, path: "~/code"))
        expectEqual(
          try parse("shell path:~/ '/opt/local/bin/mvim before'"),
          .shell(command: "/opt/local/bin/mvim before", wait: false, path: "~/"))
        expectEqual(
          try parse("shell '/bin/echo \"hello world\"'"),
          .shell(command: "/bin/echo \"hello world\"", wait: false, path: nil))
        expectEqual(
          try parse("shell \"/usr/bin/say 'hi there'\""),
          .shell(command: "/usr/bin/say 'hi there'", wait: false, path: nil))
        expectEqual(
          try parse("shell '/bin/echo it'\"'\"'s'"), .shell(command: "/bin/echo it's", wait: false, path: nil))
        expectEqual(
          try parse("shell path:'~/My Projects' wait '/usr/bin/make'"),
          .shell(command: "/usr/bin/make", wait: true, path: "~/My Projects"))
        expectEqual(try parse("shell /usr/bin/true"), .shell(command: "/usr/bin/true", wait: false, path: nil))
        expectEqual(
          try SlateSyntax.shellArguments("/bin/echo 'with single' \"and double quotes\""),
          ["/bin/echo", "with single", "and double quotes"])
        expectThrows { _ = try parse("shell wait") }
        expectThrows { _ = try parse("shell open -a Safari") }
        expectThrows { _ = try parse("shell '/bin/echo") }
        expectThrows { _ = try parse("shell ''") }
      }
    ),
    (
      "parses Slated's insert-text, open-url and keystroke",
      {
        expectEqual(try parse("insert-text 'hello'"), .insertText("hello", method: .auto))
        expectEqual(try parse("insert-text hello"), .insertText("hello", method: .auto))
        expectEqual(try parse("insert-text paste 'a longer text'"), .insertText("a longer text", method: .paste))
        expectEqual(try parse("insert-text type \"it's\""), .insertText("it's", method: .type))
        expectEqual(
          try parse("insert-text 'line 1\\nline 2\\tend\\\\'"), .insertText("line 1\nline 2\tend\\", method: .auto))
        expectEqual(try parse("insert-text 'C:\\dir'"), .insertText("C:\\dir", method: .auto))
        expectEqual(try parse("open-url 'https://example.com/a?b=c#d'"), .openURL("https://example.com/a?b=c#d"))
        expectEqual(try parse("open-url https://example.com"), .openURL("https://example.com"))
        expectEqual(try parse("keystroke cmd+shift+4"), .keystroke(KeyCombo(key: "4", modifiers: [.command, .shift])))
        expectEqual(try parse("keystroke 4:cmd,shift"), .keystroke(KeyCombo(key: "4", modifiers: [.command, .shift])))
        expectEqual(try parse("keystroke hyper+space"), .keystroke(KeyCombo(key: "space", modifiers: .hyper)))
        expectEqual(try parse("keystroke cmd++"), .keystroke(KeyCombo(key: "+", modifiers: .command)))
        expectThrows { _ = try parse("insert-text hello world") }
        expectThrows { _ = try parse("insert-text loud 'hello'") }
        expectThrows { _ = try parse("keystroke cmd+bogus") }
        expectThrows { _ = try parse("open-url") }
      }
    ),
    (
      "reports clear errors",
      {
        expectEqual(errorMessage { _ = try parse("mvoe 0;0 1;1") }, "Unknown operation \"mvoe\"")
        expectMessage(errorMessage { _ = try parse("") }, contains: "The operation is empty")
        expectMessage(
          errorMessage { _ = try parse("move 0;0") },
          contains: "Missing parameters in \"move 0;0\"", "Usage: move x;y width;height [screen]")
        expectMessage(
          errorMessage { _ = try parse("move 0 100;100") }, contains: "Expected the position as x;y, found \"0\"")
        expectMessage(
          errorMessage { _ = try parse("move 0;0 100;100 1 2") },
          contains: "Too many parameters in \"move 0;0 100;100 1 2\"")
        expectMessage(errorMessage { _ = try parse("move 0;0 100;100 bogus") }, contains: "Unknown screen \"bogus\"")
        expectMessage(
          errorMessage { _ = try parse("move screenOrginX;0 100;100") },
          contains: "Unknown variable \"screenOrginX\"", "Did you mean \"screenOriginX\"?")
        expectMessage(errorMessage { _ = try parse("push upward") }, contains: "Unknown direction \"upward\"")
        expectMessage(errorMessage { _ = try parse("push up barr") }, contains: "Unknown push style \"barr\"")
        expectMessage(errorMessage { _ = try parse("push up bar-resize:") }, contains: "bar-resize needs an expression")
        expectMessage(
          errorMessage { _ = try parse("push up bar-resize:screenSizeY/") }, contains: "\"screenSizeY/\" ends too early"
        )
        expectMessage(errorMessage { _ = try parse("resize +10% +0 middle") }, contains: "Unknown anchor \"middle\"")
        expectMessage(
          errorMessage { _ = try parse("resize +10%% +0") }, contains: "Invalid resize amount \"+10%%\"")
        expectMessage(errorMessage { _ = try parse("nudge +10 +x") }, contains: "Invalid nudge amount \"+x\"")
        expectMessage(errorMessage { _ = try parse("nudge +10") }, contains: "Missing parameters")
        expectMessage(errorMessage { _ = try parse("throw") }, contains: "Missing parameters")
        expectMessage(
          errorMessage { _ = try parse("throw 1 fullscreen") }, contains: "Unknown throw style \"fullscreen\"")
        expectMessage(errorMessage { _ = try parse("corner middle") }, contains: "Unknown corner \"middle\"")
        expectMessage(
          errorMessage { _ = try parse("corner top-left resize:100") }, contains: "Expected the size as width;height")
        expectMessage(errorMessage { _ = try parse("chain push up |") }, contains: "Missing an operation after \"|\"")
        expectMessage(
          errorMessage { _ = try parse("sequence > push up") }, contains: "Missing an operation before \">\"")
        expectMessage(errorMessage { _ = try parse("chain push up | bogus") }, contains: "Unknown operation \"bogus\"")
        expectMessage(
          errorMessage { _ = try parse("focus sideways") }, contains: "Unknown focus direction \"sideways\"")
        expectEqual(
          errorMessage { _ = try parse("focus Google Chrome") },
          "App names need quotes in \"focus Google Chrome\"; write focus 'Google Chrome'")
        expectEqual(
          errorMessage { _ = try parse("push sideways") },
          "Unknown direction \"sideways\" in \"push sideways\"; use up, down, left or right")
        expectMessage(errorMessage { _ = try parse("snapshot s save") }, contains: "Unknown snapshot option \"save\"")
        expectMessage(errorMessage { _ = try parse("grid padding:x") }, contains: "Grid padding must be a whole number")
        expectMessage(errorMessage { _ = try parse("grid 0:6") }, contains: "Grid size for screen 0")
        expectMessage(errorMessage { _ = try parse("grid left:6,6") }, contains: "Unknown grid screen \"left\"")
        expectMessage(errorMessage { _ = try parse("undo now") }, contains: "undo takes no parameters")
        expectMessage(
          errorMessage { _ = try parse("focus 'iTerm") }, contains: "Missing closing ' for the quote at column 1")
        // Error types.
        do {
          _ = try parse("teleport home")
          expect(false, "should have thrown")
        } catch let error as SlatedError {
          expectEqual(error, .unknownOperation("teleport"))
        }
        do {
          _ = try parse("push sideways")
          expect(false, "should have thrown")
        } catch let error as SlatedError {
          guard case .invalidSyntax = error else { return expect(false, "wrong case \(error)") }
        }
      }
    ),
    (
      "formats canonically",
      {
        expectEqual(
          try SlateSyntax.format(parse("push top bar-resize:screenSizeY/2")), "push up bar-resize:screenSizeY/2")
        expectEqual(try SlateSyntax.format(parse("throw left  resize")), "throw left resize")
        expectEqual(try SlateSyntax.format(parse("move 0,0 100,100")), "move 0;0 100;100")
        expectEqual(try SlateSyntax.format(parse("push up 1")), "push up none 1")
        expectEqual(try SlateSyntax.format(parse("corner top-left 2")), "corner top-left noresize 2")
        expectEqual(try SlateSyntax.format(parse("throw 1 noresize")), "throw 1")
        expectEqual(
          try SlateSyntax.format(parse("sequence focus right > push left | push right")),
          "sequence focus right > push left | push right")
        expectEqual(try SlateSyntax.format(parse("hide 'iTerm', 'Google Chrome'")), "hide 'iTerm','Google Chrome'")
        expectEqual(try SlateSyntax.format(parse("hide all-but:Finder")), "hide all-but:'Finder'")
        expectEqual(
          try SlateSyntax.format(parse("shell wait path:~/code '/opt/local/bin/mvim'")),
          "shell wait path:~/code '/opt/local/bin/mvim'")
        expectEqual(try SlateSyntax.format(parse("snapshot s stack;save-to-disk")), "snapshot s save-to-disk;stack")
        expectEqual(try SlateSyntax.format(parse("resize +10% +0 top-left")), "resize +10% +0")
        expectEqual(try SlateSyntax.format(parse("insert-text 'two\\nlines'")), "insert-text 'two\\nlines'")
        expectEqual(try SlateSyntax.format(parse("keystroke 4:cmd,shift")), "keystroke shift+cmd+4")
        expectEqual(
          SlateSyntax.format(.move(x: "screenOriginX + 10", y: "0", width: "100", height: "100", screen: nil)),
          "move 'screenOriginX + 10;0' 100;100")
        expectEqual(
          SlateSyntax.format(.throwWindow(screen: .index(1), width: "screenSizeX/2", height: nil)),
          "throw 1 resize:screenSizeX/2;windowSizeY")
      }
    ),
    (
      "format round-trips through parseOperation",
      {
        let actions: [Action] = [
          .move(x: "screenOriginX", y: "screenOriginY", width: "screenSizeX/2", height: "screenSizeY", screen: nil),
          .move(x: "0", y: "0", width: "100", height: "100", screen: .index(1)),
          .move(x: "screenOriginX + 10", y: "screenOriginY", width: "400", height: "300", screen: .orderedIndex(0)),
          .move(x: "0", y: "0", width: "100", height: "100", screen: .resolution(width: 1920, height: 1080)),
          .resize(width: "+10%", height: "-100", anchor: .bottomRight),
          .resize(width: "+0", height: "-10%", anchor: .topLeft),
          .resize(width: "screenSizeX / 2", height: "50%", anchor: .topRight),
          .push(direction: .up, style: .barResize("screenSizeY/2"), screen: nil),
          .push(direction: .down, style: .barResize("screenSizeY / 3"), screen: .relative(.left)),
          .push(direction: .left, style: .none, screen: .index(2)),
          .push(direction: .right, style: .center, screen: nil),
          .push(direction: .down, style: .bar, screen: .previous),
          .nudge(x: "+10%", y: "-100"),
          .nudge(x: "+screenSizeX / 10", y: "+0"),
          .throwWindow(screen: .relative(.right), width: "screenSizeX", height: "screenSizeY"),
          .throwWindow(screen: .next, width: nil, height: nil),
          .throwWindow(screen: .index(1), width: "screenSizeX/2", height: "screenSizeY"),
          .corner(.topLeft, width: nil, height: nil, screen: nil),
          .corner(.bottomRight, width: "screenSizeX/2", height: "screenSizeY/2", screen: nil),
          .corner(.topRight, width: nil, height: nil, screen: .relative(.up)),
          .corner(.bottomLeft, width: "400", height: "300", screen: .index(0)),
          .chain([.push(direction: .left, style: .none, screen: nil), .undo, .focusApp("Safari")]),
          .sequence([
            SequenceStep(.focus(.right)),
            SequenceStep(.push(direction: .left, style: .bar, screen: nil), keepWindow: true),
            SequenceStep(.push(direction: .right, style: .bar, screen: nil)), SequenceStep(.hint(characters: "ASDF")),
          ]),
          .layout(name: "coding"),
          .layout(name: "Two Screens | Work"),
          .focus(.left), .focus(.behind),
          .focusApp("Google Chrome"), .focusApp("Bob's \"Best\" App"),
          .snapshot(name: "work", save: true, stack: false),
          .snapshot(name: "my snapshot", save: false, stack: true),
          .deleteSnapshot(name: "work", all: true),
          .activateSnapshot(name: "work", delete: false),
          .hint(characters: nil), .hint(characters: "QWERTY"), .hint(characters: "A B"),
          .grid(padding: nil, grids: []),
          .grid(
            padding: 4,
            grids: [
              GridScreen(screen: "0", width: 6, height: 6), GridScreen(screen: "1920x1080", width: 12, height: 8),
            ]),
          .hide(.current), .show(.all), .toggle(.allBut("Finder")), .hide(.allBut("Bob's App")),
          .hide(.apps(["iTerm", "Google Chrome", "Apps, Inc.", "current"])),
          .shell(command: "/usr/bin/say hello", wait: false, path: nil),
          .shell(command: "/bin/echo \"it's\" 'fine'", wait: true, path: "~/My Projects"),
          .shell(command: "/bin/sh -c 'ls | wc > /tmp/count'", wait: false, path: "/tmp"),
          .undo, .relaunch, .switchApp,
          .insertText("¯\\_(ツ)_/¯", method: .type),
          .insertText("line 1\nline 2\ttabbed \\ backslash", method: .auto),
          .insertText("She said \"it's\" | ok > fine # yes", method: .paste),
          .insertText("", method: .auto),
          .openURL("https://example.com/search?q=a b#frag"),
          .keystroke(KeyCombo(key: "4", modifiers: [.command, .shift])),
          .keystroke(KeyCombo(key: ",", modifiers: .hyper)),
          .keystroke(KeyCombo(key: "'", modifiers: .control)),
          .keystroke(KeyCombo(key: "+", modifiers: .command)),
          .keystroke(KeyCombo(key: "space")),
        ]
        for action in actions {
          let text = SlateSyntax.format(action)
          do {
            let reparsed = try SlateSyntax.parseOperation(text)
            expect(reparsed == action, "\(action) → \"\(text)\" → \(reparsed)")
          } catch {
            expect(false, "\(action) → \"\(text)\" failed: \(error)")
          }
        }
      }
    ),
    (
      "bare strings in JSON use the operation syntax",
      {
        let json = #"["throw left  resize", "push top bar-resize:screenSizeY/2"]"#
        let actions = try JSONDecoder().decode([Action].self, from: Data(json.utf8))
        expectEqual(
          actions,
          [fullScreenThrow(.relative(.left)), .push(direction: .up, style: .barResize("screenSizeY/2"), screen: nil)])
        expectThrows { _ = try JSONDecoder().decode([Action].self, from: Data(#"["push sideways"]"#.utf8)) }
      }
    ),
    (
      "tokenizer quotes and splits",
      {
        let tokens = try SlateTokenizer.tokenize("hi 'tokenize\t\t  \"me\"' path:'~/a b'c ''")
        expectEqual(tokens.map(\.text), ["hi", "tokenize\t\t  \"me\"", "path:~/a bc", ""])
        expectEqual(tokens.map(\.isQuoted), [false, true, true, true])
        expectEqual(tokens.map(\.column), [1, 4, 23, 37])
        expectEqual(try SlateTokenizer.tokenize("  \t "), [])
        expectThrows { _ = try SlateTokenizer.tokenize("a 'b") }
        expectEqual(
          try SlateTokenizer.split("a | 'b|c' > d", separators: ["|", ">"]).map(\.text), ["a", "'b|c'", "d"])
        expectEqual(
          try SlateTokenizer.split("a | 'b|c' > d", separators: ["|", ">"]).map(\.separator), [nil, "|", ">"])
        for text in ["plain", "with space", "it's", "say \"hi\"", "both ' and \"", "'\"'\"", "", "a|b", "x#y"] {
          let quoted = SlateTokenizer.quote(text)
          let back = try SlateTokenizer.tokenize(quoted)
          expectEqual(back.count, 1)
          expectEqual(back.first?.text, text)
          expectEqual(SlateTokenizer.unquote(quoted), text)
        }
        expectEqual(SlateTokenizer.quoteIfNeeded("screenSizeX/2"), "screenSizeX/2")
        expectEqual(SlateTokenizer.quoteIfNeeded("a b"), "'a b'")
      }
    ),
  ])
