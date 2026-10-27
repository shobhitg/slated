import Foundation

@testable import SlatedCore

/// Operation strings: every form from SlateSyntaxTests plus odd whitespace, quoting, case and every
/// error path in SlateOperationParser.
private let parseInputs: [String] = [
  // From SlateSyntaxTests
  "push top bar-resize:screenSizeY/2", "grid padding:4 0:6,6 1:6,6 2:6,6", "throw right resize", "throw left  resize",
  "throw up  resize", "throw 1  resize", "move screenOriginX;screenOriginY screenSizeX/2;screenSizeY 1",
  "move 0;0 100;100", "move 0,0 100,100", "move max({0,1}),0 100;100",
  "move screenOriginX;screenOriginY screenSizeX;screenSizeY ordered:2", "resize +10% -100 bottom-right",
  "resize +10% +0", "resize screenSizeX/2 50%", "push up bar-resize:screenSizeY/2 1", "push up", "push bottom center",
  "push left bar", "push right none next", "push up 1", "nudge -100 +0", "nudge +10% -10%", "nudge +screenSizeX/10 +0",
  "throw 1 resize:screenSizeX/2;screenSizeY", "throw 0", "throw next noresize", "throw 1920x1080 resize",
  "throw down resize", "corner top-left resize:screenSizeX/2;screenSizeY/2", "corner bottom-right",
  "corner top-right resize:400;300 left", "corner bottom-left noresize 2", "corner bottom-left 2",
  "  throw\t1   resize  ", "PUSH Up BAR", "chain push up|push down", "chain push up | push down",
  "chain   push up   |   push down  ", "chain push up | push right | push down | push left",
  "sequence focus right > push left | push right", "sequence shell wait '/bin/sh -c \"ls | wc > /tmp/x\"' | undo",
  "layout myLayout", "layout 'My Layout'", "focus above", "focus behind", "focus 'iTerm'", "focus \"Google Chrome\"",
  "focus 'left'", "snapshot theName save-to-disk;stack", "snapshot theName", "snapshot theName stack",
  "delete-snapshot theName all", "delete-snapshot theName", "activate-snapshot theName delete", "hint",
  "hint QWERTYUIOP", "grid padding:5 1680x1050:16,9 1050x1680:9,16", "grid", "grid 0:4,4 0:6,6", "undo", "relaunch",
  "switch", "switch back:shift quit:q", "hide 'iTerm','Google Chrome'", "show 'iTerm', \"Google Chrome\"",
  "toggle iTerm", "hide Google Chrome", "hide 'Apps, Inc.','Other'", "hide current", "toggle all",
  "hide all-but:'iTerm'", "show all-but:'Google Chrome'", "hide all-but:Finder", "hide 'current'",
  "hide current,'iTerm'", "hide 'iTerm',,'Finder'", "hide", "shell wait path:~/code '/opt/local/bin/mvim'",
  "shell path:~/ '/opt/local/bin/mvim before'", "shell '/bin/echo \"hello world\"'",
  "shell \"/usr/bin/say 'hi there'\"",
  "shell '/bin/echo it'\"'\"'s'", "shell path:'~/My Projects' wait '/usr/bin/make'", "shell /usr/bin/true",
  "shell wait", "shell open -a Safari", "shell '/bin/echo", "shell ''", "insert-text 'hello'", "insert-text hello",
  "insert-text paste 'a longer text'", "insert-text type \"it's\"", "insert-text 'line 1\\nline 2\\tend\\\\'",
  "insert-text 'C:\\dir'", "open-url 'https://example.com/a?b=c#d'", "open-url https://example.com",
  "keystroke cmd+shift+4", "keystroke 4:cmd,shift", "keystroke hyper+space", "keystroke cmd++",
  "insert-text hello world", "insert-text loud 'hello'", "keystroke cmd+bogus", "open-url", "mvoe 0;0 1;1", "",
  "move 0;0", "move 0 100;100", "move 0;0 100;100 1 2", "move 0;0 100;100 bogus", "move screenOrginX;0 100;100",
  "push upward", "push up barr", "push up bar-resize:", "push up bar-resize:screenSizeY/", "resize +10% +0 middle",
  "resize +10%% +0", "nudge +10 +x", "nudge +10", "throw", "throw 1 fullscreen", "corner middle",
  "corner top-left resize:100", "chain push up |", "sequence > push up", "chain push up | bogus", "focus sideways",
  "focus Google Chrome", "push sideways", "snapshot s save", "grid padding:x", "grid 0:6", "grid left:6,6", "undo now",
  "focus 'iTerm", "teleport home", "snapshot s stack;save-to-disk", "resize +10% +0 top-left",
  "insert-text 'two\\nlines'",
  "by-orientation 'move screenOriginX;screenOriginY screenSizeX/3;screenSizeY' 'move screenOriginX;screenOriginY screenSizeX;screenSizeY/3'",
  // move: screens, separators, quoting
  "move 0;0 100;100 1920x1080", "move 0;0 100;100 left", "move 0;0 100;100 next", "move 0;0 100;100 prev",
  "move 0;0 100;100 -1", "move 0;0 100;100 +1", "move 0;0 100;100 01", "move 0;0 100;100 ORDERED:1",
  "move 0;0 100;100 1920X1080", "move 0;0 100;100 below", "move 0;0 100;100 top", "move 0;0 100;100 PREVIOUS",
  "move 0;0 100;100 ordered:-1", "move 0;0 100;100 1920xx1080", "move 0;0 100;100 x1920x1080",
  "move 0;0 100;100 1920x1080x", "move 0;0 100;100 1x", "move 0;0 100;100 x1080", "move 0;0 100;100 1920x1080x1",
  "move 0;0 100;100 ' 1 '", "move 0;0 100;100 １", "move 0;0 100;100 'ordered: 1'",
  "move 0;0 100;100 99999999999999999999",
  "move 'screenOriginX + 10;0' 100;100", "move screenOriginX+10;0 100;100", "move min({1,2}),max({3,4}) 10,20",
  "move 1;2;3 4;5", "move ;0 1;1", "move 0; 1;1", "move", "move a;0 1;1", "move 0;0 1;b", "move 0;0 '';1",
  "move 0;0 100;100 '1 2'", "move (1,2);0 1;1", "move 0;0 sum({1,2});1", "move 0;0 100;100 RIGHT", "MOVE 0;0 1;1",
  "Move\t0;0\t1;1", "move\u{00A0}0;0 1;1", "move\u{3000}0;0\u{3000}1;1", "move 0;0 1;1\r\n", "\u{FEFF}move 0;0 1;1",
  "move 0;0 1;1\u{200B}", "move\n0;0\n1;1",
  // resize
  "resize -10% +0 TOP-RIGHT", "resize +0 +10% bottom-left", "resize + +0", "resize % +0", "resize +abc +0",
  "resize +1.5 +0", "resize 100 200", "resize -screenSizeX/10 +0", "resize +10%", "resize 1 2 top-left extra",
  "resize '+ 10 %' +0", "resize +10% +0 Bottom-Left", "resize - +0", "resize -% +0", "resize 50% 50% top-right",
  "resize +screenSizeX* +0", "resize screenSizeZ +0", "resize", "resize +0 +0 bottom-right",
  // push
  "push top", "push above", "push bottom", "push below center", "push left bar-resize:screenSizeX/2+100",
  "push up BAR-RESIZE:screenSizeY/2", "push up bar-resize: screenSizeY/2", "push up 'bar-resize:screenSizeY / 2'",
  "push up none", "push up center 1", "push up ''", "push up '' 1", "push", "push up bar 1 2", "push up 1 2",
  "push up bogus", "push up bar-resize:'   '", "push down bar-resize:screenSizeY-100", "push LEFT None", "push up next",
  "push up bar-resize:bogus", "push right center previous", "push down bar 1920x1080", "push left bar-resize:1/0",
  // nudge
  "nudge 50 0", "nudge '' +0", "nudge +10%% +0", "nudge 10% 0", "nudge -screenSizeX/10 +0", "nudge + +0",
  "nudge +10 +10 +10", "nudge", "nudge +windowSizeX +0", "nudge '+ 10' +0", "nudge +10% +bogus",
  // throw
  "throw 1 RESIZE", "throw 1 NoResize", "throw 1 resize:100", "throw 1 resize:;100", "throw 1 resize extra",
  "throw bogus", "throw ordered:0 resize", "throw -1 resize", "throw prev",
  "throw 1 'resize:screenSizeX / 2;screenSizeY'",
  "throw 1 resize:a;b", "throw left resize:screenSizeX/2,screenSizeY", "throw 1 Resize:100;200", "throw above",
  // corner
  "corner TOP-LEFT", "corner top-left resize", "corner top-left RESIZE:1;1", "corner top-left noresize",
  "corner top-left noresize 1", "corner top-left resize 1", "corner top-left bogus", "corner top-left 1 2", "corner",
  "corner top-left resize:1;1 1 2", "corner bottom-right resize:screenSizeX/2;screenSizeY/2 1",
  "corner top-right resize:newWindowSizeX;screenSizeY", "corner bottom-left NORESIZE right",
  "corner top-left resize:a;1",
  // chain and sequence
  "chain push up", "chain push up | push down | chain push left | push right", "chain", "chain |", "chain | push up",
  "chain push up || push down", "sequence push up > > push down", "sequence push up >", "chain shell 'a|b' | undo",
  "sequence focus right>push left|push right", "chain push up | push sideways", "chain 'push up' | push down",
  "sequence push up | push down", "sequence push up > push down", "chain push up | push 'down",
  "sequence undo", "chain push up >push down", "sequence chain push up | push down", "CHAIN push up|PUSH down",
  // layout
  "layout My Layout", "layout", "layout ''", "layout 'a'b", "layout 'unclosed", "layout \"Two Screens | Work\"",
  "layout   spaced  ", "layout 'it''s'",
  // focus
  "focus left", "focus RIGHT", "focus up", "focus down", "focus top", "focus bottom", "focus BEHIND", "focus ''",
  "focus", "focus 'it''s'", "focus below", "focus \"left\"", "focus 'Safari' extra",
  // snapshots
  "snapshot theName save-to-disk", "snapshot theName SAVE-TO-DISK;STACK", "snapshot theName stack save-to-disk",
  "snapshot theName stack,save-to-disk", "snapshot theName ;stack;", "snapshot", "snapshot ''",
  "snapshot 'my snap' stack",
  "delete-snapshot theName stack", "activate-snapshot theName all", "Activate-Snapshot theName DELETE",
  "snapshot s 'save-to-disk; stack'", "delete-snapshot", "activate-snapshot theName", "snapshot s stack stack",
  // hint
  "hint 'A B'", "hint A B", "hint ''", "hint 'unclosed", "HINT asdf",
  // grid
  "grid padding:0", "grid padding:-1", "grid padding:+5", "grid padding:1.5", "grid PADDING:5",
  "grid 0:6,6 1920x1080:12,8", "grid 0:6,0", "grid 0:6,6,6", "grid 0:a,6", "grid foo", "grid :6,6", "grid -1:6,6",
  "grid 1920X1080:6,6", "grid 1920xx1080:6,6", "grid 1:6,6 0:4,4", "grid 10:1,1 2:1,1 1920x1080:1,1",
  "grid 0:6,6 padding:2", "grid padding:2 padding:3", "grid 0:+6,6", "grid 0:6,", "grid padding:", "grid 0:1,1 x:1,1",
  // hide/show/toggle
  "toggle 'iTerm'", "hide 'iTerm' , 'Finder'", "hide CURRENT", "hide All", "hide ALL-BUT:'iTerm'", "hide all-but:",
  "hide all-but:''", "hide current,all", "hide all,'x'", "hide 'a',current", "hide 'unclosed",
  "hide iTerm,Google Chrome",
  "hide ,a", "hide a,", "hide 'a'b'c'", "show 'O''Brien'", "toggle all-but:Google Chrome", "show current",
  "hide 'all-but:x'", "hide all-but:'a','b'",
  // shell
  "shell 'ls'", "shell wait 'ls'", "shell WAIT 'ls'", "shell path:/tmp 'ls'", "shell PATH:/tmp 'ls'",
  "shell path: 'ls'", "shell wait wait 'ls'", "shell path:/a path:/b 'ls'", "shell 'wait'", "shell path:/tmp", "shell",
  "shell '   '", "shell 'a' 'b'", "shell 'path:/x'", "shell path:'/my dir' 'ls -la'",
  // bare operations
  "UNDO", "relaunch x", "Switch", "undo ''",
  // by-orientation
  "by-orientation 'push left' 'push up'", "by-orientation 'push left'", "by-orientation 'push left' 'push sideways'",
  "by-orientation \"by-orientation 'push left' 'push right'\" 'push up'",
  "by-orientation 'chain push up | push down' 'undo'",
  "by-orientation", "by-orientation 'a' 'b' 'c'", "BY-ORIENTATION 'push left' 'push up'",
  // insert-text
  "insert-text ''", "insert-text TYPE 'x'", "insert-text 'type'", "insert-text type", "insert-text type paste",
  "insert-text 'type' 'x'", "insert-text auto 'x'", "insert-text", "insert-text a b c", "insert-text 'tab\\there'",
  "insert-text 'unknown \\q escape'", "insert-text 'trailing\\'", "insert-text 'a\\rb'", "insert-text '¯\\_(ツ)_/¯'",
  "insert-text paste \"She said \\\"hi\\\"\"", "insert-text Paste 'x'",
  // open-url
  "open-url a b", "open-url ''", "open-url 'https://example.com/a b'", "OPEN-URL https://x.y",
  // keystroke
  "keystroke", "keystroke a b", "keystroke f13", "keystroke ctrl+pad+", "keystroke Return", "keystroke a:ctrl,f4",
  "keystroke ':ctrl", "keystroke bogus+a", "keystroke HYPER+A", "keystroke meh+x", "keystroke fn+f1", "keystroke ⌘+a",
  "keystroke ✦+a", "keystroke 'cmd+shift+4'", "keystroke ctrl+ab", "keystroke +", "keystroke left:ctrl;cmd",
  "keystroke a:", "keystroke cmd+", "keystroke ':'",
  // whitespace and names
  "   ", "\t\n", "push\u{2028}up", "  push   up  ", "push up\u{200B}", "push\tup\tbar", "Push Up", "push\u{85}up",
  // click
  "click", "click left", "click right", "click middle", "click RIGHT", "click 2", "click right 2", "click 2 right",
  "click left 10", "click 11", "click 0", "click -1", "click +3", "click 03", "click 1.5", "click left right",
  "click 2 3",
  "click left 2 3", "click back", "click 'left'", "CLICK", "click\tright\t2", "click ''", "click mouse:left",
  // press
  "press key:w down", "press key:w up", "press mouse:left down", "press mouse:right UP", "press key:shift+w down",
  "press KEY:W Down", "press key:w", "press key:w down extra", "press", "press key:w sideways", "press key:bogus down",
  "press w down", "press mouse:back down", "press 'key:w' down", "press key:' down", "press \"key:'\" down",
  "press key:space down", "press key:rightShift down", "press key:mouse4 down", "press key:, up", "press key:# up",
  "press down key:w", "press key:hyper+a down", "press mouse:middle 'up'",
  // hold
  "hold mouse:right", "hold key:w", "hold key:shift", "hold key:ctrl", "hold key:rightCmd", "hold MOUSE:MIDDLE", "hold",
  "hold key:w key:a", "hold w", "hold key:", "hold mouse:4", "hold key:hyper", "hold key:cmd+shift+4", "hold 'key:#'",
  "hold key:alt+f4", "hold key:RIGHTALT", "hold 'mouse:left'",
  // repeat
  "repeat 0.1 'click left'", "repeat 0.05 while-held jitter:0.1 'keystroke e'", "repeat 0.1 times:50 'click left'",
  "repeat 0.1 toggle 'click'", "repeat 1 'press key:w down'", "repeat 0.1 click", "repeat 0.1 undo",
  "repeat 0.1 click left",
  "repeat 0 'click'", "repeat -1 'click'", "repeat -0 'click'", "repeat abc 'click'", "repeat inf 'click'",
  "repeat nan 'click'", "repeat 1e-400 'click'", "repeat 1e400 'click'", "repeat 0x1p-3 'click'", "repeat .5 'click'",
  "repeat 5. 'click'", "repeat 2 'click'", "repeat", "repeat 0.1", "repeat 'click'", "repeat 0.1 times:0 'click'",
  "repeat 0.1 times:-1 'click'", "repeat 0.1 times:1.5 'click'", "repeat 0.1 times: 'click'",
  "repeat 0.1 TIMES:5 'click'",
  "repeat 0.1 times:+5 'click'", "repeat 0.1 jitter:0.6 'click'", "repeat 0.1 jitter:-0.1 'click'",
  "repeat 0.1 jitter:0.5 'click'", "repeat 0.1 jitter:0 'click'", "repeat 0.1 jitter:nan 'click'",
  "repeat 0.1 jitter:abc 'click'", "repeat 0.1 jitter:.25 'click'", "repeat 0.1 jitter:0x0.8 'click'",
  "repeat 0.1 JITTER:0.2 'click'", "repeat 0.1 WHILE-HELD 'click'", "repeat 0.1 while-held toggle 'click'",
  "repeat 0.1 while-held times:3 jitter:0.2 'click'", "repeat 0.1 times:3 times:4 'click'", "repeat 0.1 bogus 'click'",
  "repeat 0.1 while-held times:3 jitter:0.2 toggle 'click'", "repeat 0.1 while-held times:3 jitter:0.2 extra x 'click'",
  "repeat 0.1 'bogus'", "repeat 0.1 'repeat 1 \"click\"'", "repeat 0.1 'sequence click | wait 0.5 | click right'",
  "repeat 0.1 'click' 'click'", "repeat 0.1 'hold key:w'", "repeat 1e15 'click'", "repeat 1e16 'click'",
  "repeat 0.30000000000000004 'click'", "repeat 0.1 ''", "repeat 0.1 times:9007199254740991 'click'",
  "repeat 0.1 \"insert-text 'hi there'\"", "REPEAT 0.25 'CLICK RIGHT 2'", "repeat 0.1 'click'extra",
  // wait
  "wait 2", "wait 0.5", "wait 0", "wait -1", "wait abc", "wait", "wait 1 2", "wait inf", "wait nan", "wait 1e-5",
  "wait 0x10", "WAIT 3", "wait '1'", "wait 1.5e1", "wait 1e20", "wait +2",
  // stop-automations, clipboard-history
  "stop-automations", "stop-automations now", "STOP-AUTOMATIONS", "clipboard-history", "clipboard-history x",
  "Clipboard-History", "stop-automations ''",
  // macros
  "sequence press key:w down | wait 2 | press key:w up | click left", "sequence click | wait 0.1 | click",
  "chain hold key:w | stop-automations", "by-orientation 'click' 'click right'", "sequence wait 1",
  "sequence hold key:shift > wait 0.5 > hold key:shift", "chain repeat 0.1 'click' | stop-automations",
]

/// Actions built directly (as JavaScript configs and the UI can), including shapes Slate syntax can't
/// write exactly. The fixture records `format` and what parsing that text gives back.
private let formatActions: [Action] = [
  // From SlateSyntaxTests' round-trip list
  .move(x: "screenOriginX", y: "screenOriginY", width: "screenSizeX/2", height: "screenSizeY", screen: nil),
  .move(x: "0", y: "0", width: "100", height: "100", screen: .index(1)),
  .move(x: "screenOriginX + 10", y: "screenOriginY", width: "400", height: "300", screen: .orderedIndex(0)),
  .move(x: "0", y: "0", width: "100", height: "100", screen: .resolution(width: 1920, height: 1080)),
  .resize(width: "+10%", height: "-100", anchor: .bottomRight), .resize(width: "+0", height: "-10%", anchor: .topLeft),
  .resize(width: "screenSizeX / 2", height: "50%", anchor: .topRight),
  .push(direction: .up, style: .barResize("screenSizeY/2"), screen: nil),
  .push(direction: .down, style: .barResize("screenSizeY / 3"), screen: .relative(.left)),
  .push(direction: .left, style: .none, screen: .index(2)), .push(direction: .right, style: .center, screen: nil),
  .push(direction: .down, style: .bar, screen: .previous), .nudge(x: "+10%", y: "-100"),
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
    SequenceStep(.focus(.right)), SequenceStep(.push(direction: .left, style: .bar, screen: nil), keepWindow: true),
    SequenceStep(.push(direction: .right, style: .bar, screen: nil)), SequenceStep(.hint(characters: "ASDF")),
  ]),
  .layout(name: "coding"), .layout(name: "Two Screens | Work"), .focus(.left), .focus(.behind),
  .focusApp("Google Chrome"), .focusApp("Bob's \"Best\" App"), .snapshot(name: "work", save: true, stack: false),
  .snapshot(name: "my snapshot", save: false, stack: true), .deleteSnapshot(name: "work", all: true),
  .activateSnapshot(name: "work", delete: false), .hint(characters: nil), .hint(characters: "QWERTY"),
  .hint(characters: "A B"), .grid(padding: nil, grids: []),
  .grid(
    padding: 4,
    grids: [GridScreen(screen: "0", width: 6, height: 6), GridScreen(screen: "1920x1080", width: 12, height: 8)]),
  .hide(.current), .show(.all), .toggle(.allBut("Finder")), .hide(.allBut("Bob's App")),
  .hide(.apps(["iTerm", "Google Chrome", "Apps, Inc.", "current"])),
  .shell(command: "/usr/bin/say hello", wait: false, path: nil),
  .shell(command: "/bin/echo \"it's\" 'fine'", wait: true, path: "~/My Projects"),
  .shell(command: "/bin/sh -c 'ls | wc > /tmp/count'", wait: false, path: "/tmp"), .undo, .relaunch, .switchApp,
  .insertText("¯\\_(ツ)_/¯", method: .type), .insertText("line 1\nline 2\ttabbed \\ backslash", method: .auto),
  .insertText("She said \"it's\" | ok > fine # yes", method: .paste), .insertText("", method: .auto),
  .openURL("https://example.com/search?q=a b#frag"), .keystroke(KeyCombo(key: "4", modifiers: [.command, .shift])),
  .keystroke(KeyCombo(key: ",", modifiers: .hyper)), .keystroke(KeyCombo(key: "'", modifiers: .control)),
  .keystroke(KeyCombo(key: "+", modifiers: .command)), .keystroke(KeyCombo(key: "space")),
  // SettingsUITests' samples (the action form round-trips every operation)
  .resize(width: "+10%", height: "-5%", anchor: .bottomRight), .push(direction: .up, style: .bar, screen: .next),
  .nudge(x: "+10%", y: "-20"), .throwWindow(screen: .index(1), width: "screenSizeX", height: "screenSizeY"),
  .layout(name: "Coding"), .focusApp("Mail"), .activateSnapshot(name: "work", delete: true),
  .grid(padding: 4, grids: [GridScreen(screen: "0", width: 6, height: 4)]), .show(.apps(["Mail", "Notes"])),
  .toggle(.current), .shell(command: "say hi", wait: true, path: "/tmp"), .insertText("Hello\nWorld", method: .paste),
  .openURL("https://example.com"),
  .byOrientation(
    landscape: .push(direction: .left, style: .none, screen: nil),
    portrait: .corner(.topLeft, width: nil, height: nil, screen: nil)),
  // Shapes that come back equivalent rather than identical, and other edge cases
  .throwWindow(screen: .index(1), width: "screenSizeX/2", height: nil),
  .throwWindow(screen: .index(0), width: nil, height: "screenSizeY"),
  .corner(.topLeft, width: nil, height: "100", screen: nil),
  .corner(.topRight, width: "50", height: nil, screen: .next),
  .chain([.chain([.undo, .relaunch]), .undo]),
  .sequence([SequenceStep(.sequence([SequenceStep(.undo)])), SequenceStep(.relaunch)]),
  .chain([]), .sequence([]), .hide(.apps([])), .hide(.apps(["only"])),
  .move(x: "", y: "0", width: "100", height: "100", screen: nil),
  .move(x: "a#b", y: "c|d", width: "e,f", height: "g>h", screen: nil),
  .move(x: "it's", y: "0", width: "1", height: "1", screen: .orderedIndex(-1)), .layout(name: ""), .focusApp(""),
  .snapshot(name: "a b", save: true, stack: true), .deleteSnapshot(name: "x'y", all: false),
  .activateSnapshot(name: "", delete: true), .hint(characters: ""),
  .grid(padding: 0, grids: [GridScreen(screen: "1920x1080", width: 1, height: 1)]),
  .grid(
    padding: nil, grids: [GridScreen(screen: "1", width: 2, height: 3), GridScreen(screen: "0", width: 4, height: 5)]),
  .grid(
    padding: nil, grids: [GridScreen(screen: "10", width: 1, height: 1), GridScreen(screen: "2", width: 1, height: 1)]),
  .shell(command: "it's \"quoted\"", wait: false, path: "a b"), .shell(command: "", wait: true, path: nil),
  .insertText("tab\there", method: .auto), .insertText("back\\slash \\n literal", method: .paste),
  .insertText("'\"'\"", method: .type), .keystroke(KeyCombo(key: "pad+", modifiers: .command)),
  .keystroke(KeyCombo(key: "+")), .keystroke(KeyCombo(key: "a", modifiers: [.function, .control])),
  .keystroke(KeyCombo(key: "a", modifiers: [.function, .control, .option, .shift, .command])),
  .keystroke(KeyCombo(key: "\"", modifiers: .control)), .keystroke(KeyCombo(key: "#")),
  .keystroke(KeyCombo(key: "left", modifiers: .meh)),
  .byOrientation(landscape: .focusApp("Bob's"), portrait: .shell(command: "say \"hi\"", wait: false, path: nil)),
  .byOrientation(
    landscape: .byOrientation(landscape: .undo, portrait: .relaunch),
    portrait: .push(direction: .up, style: .none, screen: nil)),
  .openURL(""), .push(direction: .up, style: .none, screen: .resolution(width: 1920, height: 1080)),
  .resize(width: "+10%", height: "+0", anchor: .topLeft),
  .throwWindow(screen: .previous, width: "screenSizeX", height: "screenSizeY"),
  .throwWindow(screen: .index(0), width: "screenSizeX", height: "screenSizeX"),
  .push(direction: .left, style: .barResize(""), screen: nil),
  .push(direction: .left, style: .barResize("a b"), screen: .next),
  .nudge(x: "", y: "+0"), .resize(width: "a b", height: "+0", anchor: .bottomLeft), .focusApp("left"),
  .layout(name: "it's \"x\""), .hide(.allBut("")), .show(.apps(["a'b", "c\"d", "e'f\"g"])),
  // Automation and clipboard history
  .click(.left, count: 1), .click(.right, count: 2), .click(.middle, count: 10), .click(.left, count: 0),
  .click(.right, count: 25), .press(.key(KeyCombo(key: "w")), phase: .down), .press(.mouse(.right), phase: .up),
  .press(.key(KeyCombo(key: "'", modifiers: .shift)), phase: .down), .press(.key(KeyCombo(key: "shift")), phase: .up),
  .hold(.mouse(.left)), .hold(.mouse(.middle)), .hold(.key(KeyCombo(key: "rightShift"))),
  .hold(.key(KeyCombo(key: "#"))),
  .hold(.key(KeyCombo(key: ",", modifiers: .hyper))),
  .hold(.key(KeyCombo(key: "space", modifiers: [.control, .function]))),
  .autoRepeat(.click(.left, count: 1), interval: 0.1, mode: .toggle),
  .autoRepeat(.keystroke(KeyCombo(key: "e")), interval: 0.05, mode: .whileHeld, times: nil, jitter: 0.1),
  .autoRepeat(.click(.left, count: 1), interval: 0.1, mode: .toggle, times: 50),
  .autoRepeat(.insertText("it's \"x\"", method: .type), interval: 2, mode: .whileHeld, times: 3, jitter: 0.5),
  .autoRepeat(
    .sequence([
      SequenceStep(.press(.key(KeyCombo(key: "w")), phase: .down)), SequenceStep(.wait(0.5)),
      SequenceStep(.press(.key(KeyCombo(key: "w")), phase: .up)),
    ]), interval: 1, mode: .toggle),
  .autoRepeat(.autoRepeat(.click(.left, count: 1), interval: 1, mode: .toggle), interval: 2, mode: .toggle),
  .autoRepeat(.click(.left, count: 1), interval: 1e-3, mode: .toggle),
  .autoRepeat(.click(.left, count: 1), interval: 0.1, mode: .toggle, times: nil, jitter: 0.123456789),
  .autoRepeat(.click(.left, count: 1), interval: 1e15, mode: .whileHeld, times: 1, jitter: 0),
  .autoRepeat(.focusApp("Bob's"), interval: 0.75, mode: .toggle), .wait(0), .wait(1.5), .wait(2), .wait(0.1 + 0.2),
  .wait(1e20), .wait(1e-7), .stopAutomations, .clipboardHistory,
  .sequence([
    SequenceStep(.press(.key(KeyCombo(key: "w")), phase: .down)), SequenceStep(.wait(2)),
    SequenceStep(.press(.key(KeyCombo(key: "w")), phase: .up)), SequenceStep(.click(.left, count: 1)),
  ]),
  .sequence([SequenceStep(.hold(.key(KeyCombo(key: "shift")))), SequenceStep(.wait(1), keepWindow: true)]),
  .chain([.hold(.key(KeyCombo(key: "shift"))), .stopAutomations]),
  .byOrientation(landscape: .click(.left, count: 2), portrait: .clipboardHistory),
]

/// Action JSON as written in config.json or by `slate.operation(name, params)`.
private let decodeInputs: [String] = [
  #""throw left  resize""#, #""push top bar-resize:screenSizeY/2""#, #""push sideways""#, #""""#, #""mvoe 1;1 1;1""#,
  #"{"op":"move","x":"screenOriginX","y":"screenOriginY","width":"screenSizeX/2","height":"screenSizeY"}"#,
  #"{"op":"move","x":0,"y":0.5,"width":100,"height":1e21}"#,
  // NumericEdgeTests
  #"{"op": "move", "x": 1e21, "y": 0, "width": 100, "height": 1e300}"#,
  #"{"op":"move","x":-0.0,"y":1e15,"width":999999999999999,"height":123.456}"#,
  #"{"op":"move","x":1e-7,"y":0.1,"width":2.5e-5,"height":100.0}"#,
  #"{"op":"move","x":1.5e300,"y":-1.5,"width":12345678901234567890,"height":-1e15}"#,
  #"{"op":"move","x":0.000123,"y":1e16,"width":4.35,"height":-0.5}"#,
  #"{"op":"move","x":"0","y":"0","width":"1","height":"1","screen":1}"#,
  #"{"op":"move","x":"0","y":"0","width":"1","height":"1","screen":"ordered:2"}"#,
  #"{"op":"move","x":"0","y":"0","width":"1","height":"1","screen":"1920x1080"}"#,
  #"{"op":"move","x":"0","y":"0","width":"1","height":"1","screen":"left"}"#,
  #"{"op":"move","x":"0","y":"0","width":"1","height":"1","screen":"next"}"#,
  #"{"op":"move","x":"0","y":"0","width":"1","height":"1","screen":"bogus"}"#,
  #"{"op":"move","x":"0","y":"0","width":"1","height":"1","screen":1.5}"#,
  #"{"op":"move","x":"0","y":"0","width":"1","height":"1","screen":true}"#,
  #"{"op":"move","x":"0","y":"0","width":"1","height":"1","screen":null}"#,
  #"{"op":"move","x":"0","y":"0","width":"1","height":"1","screen":"-1"}"#,
  #"{"op":"move","x":"0","y":"0","width":"1","height":"1","screen":" 2 "}"#,
  #"{"op":"move","x":"0","y":"0","width":"1","height":"1","screen":"Prev"}"#,
  #"{"op":"move","x":"0"}"#, #"{"op":"move","x":true,"y":"0","width":"1","height":"1"}"#,
  #"{"op":"move","x":null,"y":"0","width":"1","height":"1"}"#,
  #"{"op":"move","x":[1],"y":"0","width":"1","height":"1"}"#,
  #"{"op":"move","x":"not validated!","y":"","width":"1","height":"1"}"#,
  #"{"op":"resize"}"#, #"{"op":"resize","width":"+10%","anchor":"bottom-right"}"#,
  #"{"op":"resize","anchor":"middle"}"#,
  #"{"op":"resize","anchor":"Bottom-Right"}"#, #"{"op":"resize","width":true}"#,
  #"{"op":"resize","width":-10,"height":5}"#,
  #"{"op":"resize","anchor":"top-left"}"#,
  #"{"op":"push","direction":"top","style":"bar-resize:screenSizeY/2"}"#, #"{"op":"push","direction":"UP"}"#,
  #"{"op":"push","direction":"sideways"}"#, #"{"op":"push","direction":"left","style":"bogus"}"#,
  #"{"op":"push","direction":"left","style":"none"}"#, #"{"op":"push","direction":"left","style":"bar-resize:"}"#,
  #"{"op":"push"}"#, #"{"op":"push","direction":5}"#, #"{"op":"push","direction":"below","style":"CENTER","screen":0}"#,
  #"{"op":"push","direction":"left","style":" bar "}"#, #"{"op":"push","direction":"left","style":""}"#,
  #"{"op":"push","direction":"left","style":5}"#,
  #"{"op":"nudge"}"#, #"{"op":"nudge","x":10}"#, #"{"op":"nudge","x":"+10%","y":"-5"}"#,
  #"{"op":"throw","screen":"right","width":"screenSizeX","height":"screenSizeY"}"#, #"{"op":"throw","screen":0}"#,
  #"{"op":"throw"}"#, #"{"op":"throw","screen":"left","width":100}"#, #"{"op":"throw","screen":"above"}"#,
  #"{"op":"corner","direction":"top-left"}"#, #"{"op":"corner","direction":"TOP-LEFT"}"#,
  #"{"op":"corner","direction":"middle"}"#,
  #"{"op":"corner","direction":"top-left","width":"screenSizeX/2","height":"screenSizeY/2","screen":"1"}"#,
  #"{"op":"corner"}"#,
  #"{"op":"chain","operations":["push up",{"op":"push","direction":"down"}]}"#, #"{"op":"chain"}"#,
  #"{"op":"chain","operations":[]}"#, #"{"op":"chain","operations":["push sideways"]}"#,
  #"{"op":"chain","operations":"push up"}"#,
  #"{"op":"sequence","operations":["focus right","push left"]}"#,
  #"{"op":"sequence","steps":[{"action":"focus right","keepWindow":false},{"action":"push left","keepWindow":true}]}"#,
  #"{"op":"sequence","steps":[{"action":"focus right"}]}"#, #"{"op":"sequence","steps":[],"operations":["undo"]}"#,
  #"{"op":"sequence","steps":[{"action":"focus right","keepWindow":null},{"action":"undo","keepWindow":true}]}"#,
  #"{"op":"sequence","steps":[{"keepWindow":true}]}"#, #"{"op":"sequence","steps":[{"action":"undo","keepWindow":"yes"}]}"#,
  #"{"op":"sequence","steps":[{"action":"undo","keepWindow":false}]}"#, #"{"op":"sequence"}"#,
  #"{"op":"layout","name":"coding"}"#, #"{"op":"layout"}"#, #"{"op":"layout","name":42}"#,
  #"{"op":"focus","direction":"left"}"#, #"{"op":"focus","direction":"behind"}"#, #"{"op":"focus","direction":"top"}"#,
  #"{"op":"focus","app":"Safari"}"#, #"{"op":"focus","app":"Safari","direction":"left"}"#, #"{"op":"focus"}"#,
  #"{"op":"focus","direction":"sideways"}"#, #"{"op":"focus","app":5}"#, #"{"op":"focus","app":null,"direction":"up"}"#,
  #"{"op":"snapshot","name":"work","save":true}"#, #"{"op":"snapshot","name":"work","save":"yes"}"#,
  #"{"op":"snapshot","name":"work","save":false,"stack":true}"#, #"{"op":"snapshot"}"#,
  #"{"op":"delete-snapshot","name":"w","all":true}"#, #"{"op":"activate-snapshot","name":"w","delete":true}"#,
  #"{"op":"activate-snapshot","name":"w","delete":null}"#,
  #"{"op":"hint"}"#, #"{"op":"hint","characters":"ASDF"}"#, #"{"op":"hint","characters":5}"#,
  #"{"op":"grid","padding":4,"grids":{"0":{"width":6,"height":6},"1920x1080":{"width":12,"height":8}}}"#,
  #"{"op":"grid"}"#,
  #"{"op":"grid","grids":{"10":{"width":1,"height":1},"2":{"width":1,"height":1},"1":{"width":1,"height":1}}}"#,
  #"{"op":"grid","padding":4.0}"#, #"{"op":"grid","padding":4.5}"#, #"{"op":"grid","grids":{"0":{"width":6}}}"#,
  #"{"op":"grid","grids":{"0":{"width":6,"height":6,"extra":1}}}"#, #"{"op":"grid","grids":[]}"#,
  #"{"op":"grid","padding":-3,"grids":{}}"#, #"{"op":"grid","grids":{"b":{"width":0,"height":-1}}}"#,
  #"{"op":"hide","app":"current"}"#, #"{"op":"hide","app":"all"}"#, #"{"op":"hide","app":"all-but:Finder"}"#,
  #"{"op":"hide","app":["iTerm","Safari"]}"#, #"{"op":"hide","app":"Safari"}"#, #"{"op":"show","app":"ALL"}"#,
  #"{"op":"toggle","app":"All-But:X"}"#, #"{"op":"hide"}"#, #"{"op":"hide","app":[]}"#, #"{"op":"hide","app":5}"#,
  #"{"op":"show","app":"all-but:"}"#, #"{"op":"toggle","app":["current"]}"#,
  #"{"op":"shell","command":"ls","wait":true,"path":"/tmp"}"#, #"{"op":"shell"}"#,
  #"{"op":"shell","command":"ls","path":5}"#,
  #"{"op":"undo"}"#, #"{"op":"relaunch"}"#, #"{"op":"switch"}"#, #"{"op":"undo","extra":1}"#,
  #"{"op":"by-orientation","landscape":"push left","portrait":{"op":"push","direction":"up"}}"#,
  #"{"op":"by-orientation","landscape":"push left"}"#,
  #"{"op":"insert-text","text":"hi"}"#, #"{"op":"insert-text","text":"hi","method":"paste"}"#,
  #"{"op":"insert-text","text":"hi","method":"auto"}"#, #"{"op":"insert-text","text":"hi","method":"bogus"}"#,
  #"{"op":"insert-text"}"#, #"{"op":"insert-text","text":3.5}"#,
  #"{"op":"insert-text","text":"multi\nline \u00e9 \ud83d\ude00"}"#,
  #"{"op":"open-url","url":"https://example.com"}"#, #"{"op":"open-url"}"#,
  #"{"op":"keystroke","keys":"cmd+shift+4"}"#, #"{"op":"keystroke","keys":"bogus+a"}"#,
  #"{"op":"keystroke","keys":"Return"}"#,
  #"{"op":"keystroke","keys":""}"#, #"{"op":"keystroke"}"#, #"{"op":"keystroke","keys":5}"#,
  #"{"op":"keystroke","keys":"ctrl+ab"}"#,
  #"{"op":"teleport"}"#, #"{"op":5}"#, #"{}"#, #"[]"#, #"5"#, #"null"#, #"true"#,
  #"{"op":"MOVE","x":"0","y":"0","width":"1","height":"1"}"#,
  #"{"op":"move","op2":"x","x":"0","y":"0","width":"1","height":"1","screen":"0"}"#,
  // Automation and clipboard history
  #"{"op":"click"}"#, #"{"op":"click","button":"right"}"#, #"{"op":"click","button":"middle","count":2}"#,
  #"{"op":"click","count":0}"#, #"{"op":"click","count":-3}"#, #"{"op":"click","count":1}"#,
  #"{"op":"click","count":11}"#,
  #"{"op":"click","count":1.5}"#, #"{"op":"click","count":"2"}"#, #"{"op":"click","button":"RIGHT"}"#,
  #"{"op":"click","button":"back"}"#, #"{"op":"click","button":5}"#, #"{"op":"click","button":null}"#,
  #"{"op":"click","count":null}"#, #"{"op":"click","count":2.0}"#, #"{"op":"click","button":"left","count":1e2}"#,
  #"{"op":"press","input":"key:w","phase":"down"}"#, #"{"op":"press","input":"mouse:left","phase":"up"}"#,
  #"{"op":"press","input":"KEY:Shift+W","phase":"down"}"#, #"{"op":"press","input":"key:w"}"#,
  #"{"op":"press","phase":"down"}"#, #"{"op":"press","input":"key:w","phase":"DOWN"}"#,
  #"{"op":"press","input":"key:bogus","phase":"down"}"#, #"{"op":"press","input":"w","phase":"down"}"#,
  #"{"op":"press","input":5,"phase":"down"}"#, #"{"op":"press","input":null,"phase":"down"}"#,
  #"{"op":"press","input":"key:w","phase":null}"#, #"{"op":"press","input":"bogus","phase":"bogus"}"#,
  #"{"op":"press","input":"key:w","phase":"bogus"}"#,
  #"{"op":"press","input":"mouse:Middle","phase":"up","extra":true}"#,
  #"{"op":"hold","input":"mouse:right"}"#, #"{"op":"hold","input":"key:shift"}"#,
  #"{"op":"hold","input":"key:rightcmd"}"#,
  #"{"op":"hold"}"#, #"{"op":"hold","input":"mouse:back"}"#, #"{"op":"hold","input":["key:w"]}"#,
  #"{"op":"hold","input":" key:w "}"#, #"{"op":"hold","input":"key:"}"#, #"{"op":"hold","input":"key:hyper+mouse4"}"#,
  #"{"op":"repeat","action":{"op":"click","button":"left"},"interval":0.1}"#,
  #"{"op":"repeat","action":"click left","interval":0.1,"mode":"while-held","times":5,"jitter":0.2}"#,
  #"{"op":"repeat","action":"click","interval":0.1,"mode":"toggle"}"#,
  #"{"op":"repeat","action":"click","interval":0.1,"jitter":0}"#, #"{"op":"repeat","action":"click","interval":0}"#,
  #"{"op":"repeat","action":"click","interval":-1}"#, #"{"op":"repeat","action":"click"}"#,
  #"{"op":"repeat","action":"click","interval":"0.1"}"#, #"{"op":"repeat","action":"click","interval":0.1,"times":0}"#,
  #"{"op":"repeat","action":"click","interval":0.1,"times":1}"#,
  #"{"op":"repeat","action":"click","interval":0.1,"times":-2}"#,
  #"{"op":"repeat","action":"click","interval":0.1,"times":1.5}"#,
  #"{"op":"repeat","action":"click","interval":0.1,"jitter":0.51}"#,
  #"{"op":"repeat","action":"click","interval":0.1,"jitter":-0.01}"#,
  #"{"op":"repeat","action":"click","interval":0.1,"jitter":0.5}"#,
  #"{"op":"repeat","action":"click","interval":0.1,"jitter":"0.1"}"#,
  #"{"op":"repeat","action":"click","interval":0.1,"mode":"WHILE-HELD"}"#,
  #"{"op":"repeat","action":"click","interval":0.1,"mode":"hold"}"#, #"{"op":"repeat","interval":0.1}"#,
  #"{"op":"repeat","action":"bogus","interval":0.1}"#, #"{"op":"repeat","action":{"op":"teleport"},"interval":0.1}"#,
  #"{"op":"repeat","action":"click","interval":0,"times":0}"#, #"{"op":"repeat","action":"bogus","interval":0}"#,
  #"{"op":"repeat","action":"bogus","interval":0.1,"mode":"bogus"}"#,
  #"{"op":"repeat","action":"click","interval":0.1,"times":0,"jitter":0.9}"#,
  #"{"op":"repeat","action":"click","interval":0.1,"jitter":0.9,"mode":"bogus"}"#,
  #"{"op":"repeat","action":"click","interval":1e300}"#,
  #"{"op":"repeat","action":"click","interval":0.1,"times":null,"jitter":null,"mode":null}"#,
  #"{"op":"repeat","action":{"op":"repeat","action":"click","interval":1},"interval":2}"#,
  #"{"op":"repeat","action":"click","interval":null}"#, #"{"op":"repeat","action":null,"interval":0.1}"#,
  #"{"op":"repeat","action":"click right 2","interval":2,"times":3,"jitter":0.25,"mode":"while-held"}"#,
  #"{"op":"wait","seconds":2}"#, #"{"op":"wait","seconds":0.5}"#, #"{"op":"wait","seconds":0}"#,
  #"{"op":"wait","seconds":-0.0}"#, #"{"op":"wait","seconds":-1}"#, #"{"op":"wait"}"#, #"{"op":"wait","seconds":"1"}"#,
  #"{"op":"wait","seconds":null}"#, #"{"op":"wait","seconds":1e-7}"#, #"{"op":"wait","seconds":1e300}"#,
  #"{"op":"stop-automations"}"#, #"{"op":"stop-automations","extra":1}"#, #"{"op":"clipboard-history"}"#,
  #"{"op":"Clipboard-History"}"#, #""stop-automations""#, #""clipboard-history now""#, #""repeat 0.1 'click'""#,
  #"{"op":"sequence","operations":[{"op":"press","input":"key:w","phase":"down"},{"op":"wait","seconds":2},"press key:w up","click left"]}"#,
  #"{"op":"chain","operations":["hold key:shift",{"op":"stop-automations"}]}"#,
]

func operationFixtures() -> FixtureFile {
  var parse: [J] = []
  for input in parseInputs {
    var item: [String: J] = ["input": .string(input)]
    do {
      let action = try SlateSyntax.parseOperation(input)
      let json = actionJ(action)
      item["action"] = json
      item["isWindowGeometry"] = .bool(action.isWindowGeometry)
      let text = SlateSyntax.format(action)
      item["format"] = .string(text)
      // JavaScript works on the JSON form; for a grid whose screens aren't sorted, the JSON form
      // (and so its formatting) lists them sorted.
      let canonical = try JSONDecoder().decode(Action.self, from: JSONEncoder().encode(action))
      let canonicalText = SlateSyntax.format(canonical)
      if canonicalText != text { item["formatCanonical"] = .string(canonicalText) }
      do {
        let reparsed = try SlateSyntax.parseOperation(canonicalText)
        item["roundTrips"] = .bool(reparsed == canonical)
        if reparsed != canonical { item["reparsed"] = actionJ(reparsed) }
      } catch {
        item["reparseError"] = errorJ(error)
      }
    } catch {
      item["error"] = errorJ(error)
    }
    parse.append(.object(item))
  }

  var format: [J] = []
  for action in formatActions {
    // The JSON form is what JavaScript sees, so format what it decodes to.
    let json = actionJ(action)
    let decoded = try! JSONDecoder().decode(Action.self, from: JSONEncoder().encode(action))
    var item: [String: J] = ["action": json]
    let text = SlateSyntax.format(decoded)
    item["format"] = .string(text)
    do {
      let reparsed = try SlateSyntax.parseOperation(text)
      item["reparsed"] = actionJ(reparsed)
      item["roundTrips"] = .bool(reparsed == decoded)
    } catch {
      item["reparseError"] = errorJ(error)
    }
    format.append(.object(item))
  }

  var decode: [J] = []
  for input in decodeInputs {
    var item: [String: J] = ["json": .string(input)]
    item.merge(outcome("action") { actionJ(try JSONDecoder().decode(Action.self, from: Data(input.utf8))) }) { a, _ in a
    }
    decode.append(.object(item))
  }

  return FixtureFile(
    name: "operations.json",
    description:
      "Slate operation syntax: SlateSyntax.parseOperation (canonical Action JSON exactly as Swift encodes it, or the "
      + "error), SlateSyntax.format, and Action decoding from config JSON. `formatCanonical` is the format of the "
      + "JSON form when it differs (grid screens are sorted in JSON).",
    sections: ["parse": parse, "format": format, "decode": decode])
}
