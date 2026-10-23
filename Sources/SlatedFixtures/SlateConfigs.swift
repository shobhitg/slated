import Foundation

@testable import SlatedCore

private let home = "/Users/tester"

private struct SlateCase {
  var name: String
  var text: String
  var path: String? = "\(home)/.slate"
  var files: [String: String] = [:]
}

private let deepChain: [String: String] = {
  var files: [String: String] = [:]
  for i in 1...20 { files["\(home)/deep\(i).slate"] = "bind \(i % 10):ctrl push up\nsource deep\(i + 1).slate" }
  return files
}()

private let cases: [SlateCase] = [
  // From SlateConfigParserTests
  SlateCase(
    name: "typical config",
    text: """
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
      """),
  SlateCase(name: "stable ids", text: "bind a:ctrl push up\nbind b:ctrl push down\nbind a:ctrl push up"),
  SlateCase(
    name: "stable ids after unrelated edits",
    text: "# new comment\nbind a:ctrl  push up\nbind b:ctrl push left\nbind a:ctrl push up"),
  SlateCase(
    name: "stable ids in another file", text: "bind a:ctrl push up\nbind b:ctrl push down", path: "\(home)/other.slate"),
  SlateCase(name: "no path", text: "bind a:ctrl push up\nbind a:ctrl push up\nbnid x", path: nil),
  SlateCase(name: "modal bindings", text: "bind 1:f4,ctrl,alt push left bar\nbind 2:ctrl,f4:toggle push right bar"),
  SlateCase(
    name: "aliases",
    text: """
      alias hyper ctrl;shift;alt;cmd
      alias half screenSizeX/2
      alias left-half move screenOriginX;screenOriginY ${half};screenSizeY
      alias bot-right-2nd-mon move screenOriginX+2*screenSizeX/3;screenOriginY+screenSizeY/2 screenSizeX/3;screenSizeY/2 1
      bind a:${hyper} ${left-half}
      bind b:${hyper} ${bot-right-2nd-mon}
      bind c:${hyper} push left bar-resize:${half}
      bind d:${hyper} ${undefined}
      bind e:${hyper} ${lft-half}
      """),
  SlateCase(
    name: "alias before definition",
    text:
      "bind a:ctrl ${full}\nalias full move screenOriginX;screenOriginY screenSizeX;screenSizeY\nbind b:ctrl ${full}"),
  SlateCase(
    name: "layouts",
    text: """
      layout myLayout 'iTerm' push up bar-resize:screenSizeY/2 | push down bar-resize:screenSizeY/2
      layout myLayout 'Google Chrome':IGNORE_FAIL,REPEAT push left bar-resize:screenSizeX/2|push right bar-resize:screenSizeX/2
      layout myLayout BEFORE shell path:~/ '/opt/local/bin/mvim before'
      layout myLayout AFTER shell path:~/ '/opt/local/bin/mvim after'
      layout myLayout BEFORE undo
      layout other 'Mail':MAIN_FIRST,SORT_TITLE,TITLE_ORDER=Inbox;Drafts,TITLE_ORDER_REGEX='^Re: .*;^Fwd' corner top-left
      layout other Safari:REPEAT_LAST,MAIN_LAST throw 1 resize
      """),
  SlateCase(
    name: "layout replaces an app", text: "layout l 'A' push up\nlayout l 'B' push down\nlayout l 'A':REPEAT push left"),
  SlateCase(
    name: "layout problems",
    text: """
      layout l 'A' push up | bogus
      layout l 'A':FLY push up
      layout l 'A'
      layout l BEFORE:REPEAT undo
      layout l 'A':TITLE_ORDER_REGEX=( push up
      layout l 'A':TITLE_ORDER push up
      layout l 'A':MAIN_FIRST,MAIN_LAST push up
      """),
  SlateCase(
    name: "defaults",
    text: """
      default myLayout count:2
      default myLayout2 resolutions:1440x900;1024x768;1680X1050
      default 'Big Desk' resolutions:2560x1440,1920x1080
      default broken count:zero
      default broken screens:3
      default broken
      default broken resolutions:1440by900
      """),
  SlateCase(
    name: "sources",
    text: """
      source ~/.slate.extra
      bind g:ctrl ${full}
      source configs/more.slate
      source /etc/slate/shared
      source ~/missing.slate if_exists
      source ~/missing.slate
      source '~/My Configs/spaced.slate'
      source ~/.slate.js
      source ~/.slate.extra sometimes
      """,
    files: [
      "\(home)/.slate.extra":
        "alias full move screenOriginX;screenOriginY screenSizeX;screenSizeY\nbind f:ctrl ${full}",
      "\(home)/configs/more.slate": "bind m:ctrl push up\nsource ~/.slate.deeper",
      "\(home)/.slate.deeper": "bind d:ctrl push down\nbind x:ctrl nonsense",
      "/etc/slate/shared": "config orderScreensLeftToRight false",
      "\(home)/My Configs/spaced.slate": "bind s:ctrl undo",
    ]),
  SlateCase(
    name: "source loops", text: "source a.slate\nbind c:ctrl undo",
    files: [
      "\(home)/a.slate": "bind a:ctrl undo\nsource b.slate",
      "\(home)/b.slate": "bind b:ctrl undo\nsource ~/a.slate\nsource ~/.slate",
    ]),
  SlateCase(
    name: "comments",
    text: """
      # a comment
         # an indented comment
      bind a:ctrl push up # trailing comment
      bind b:ctrl shell '/bin/echo #not-a-comment' # but this is
      bind ':ctrl,shift,alt,cmd move screenOriginX;screenOriginY screenSizeX/2;screenSizeY # the ' key
      bind ":ctrl push down #"
      bind c:ctrl hint ABC#DEF
      config windowHintsFontName "Helvetica Neue" # with spaces
      """),
  SlateCase(
    name: "bad lines and CRLF",
    text: "bind a:ctrl push up\r\nbind b:ctrl push sideways\r\n\r\nbnid c:ctrl push up\r\nbind d:bogus push up\r\n"
      + "bind e:ctrl\r\nconfig\r\nalias lonely\r\nbind f:ctrl push down\r\n"),
  SlateCase(
    name: "unknown and per-app settings",
    text: "config defaultToCurentScreen true\nconfig snapshotTitleMatch:'iTerm' sequential\nconfig undoMaxStackSize 20"),
  SlateCase(
    name: "README bindings",
    text: """
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
      """),
  // Line breaks and encodings
  SlateCase(name: "byte order mark", text: "\u{FEFF}bind a:ctrl push up\n\u{FEFF}bind b:ctrl push down"),
  SlateCase(name: "lone CR line breaks", text: "bind a:ctrl push up\rbind b:ctrl push sideways\rbind c:ctrl push down"),
  SlateCase(
    name: "unusual line breaks",
    text:
      "bind a:ctrl push up\u{2028}bind b:ctrl push down\u{0B}bind c:ctrl push left\u{0C}bind d:ctrl bogus\u{85}bind e:ctrl undo\u{2029}bnid"
  ),
  SlateCase(name: "blank and whitespace lines", text: "\n\n   \n\t\nbind a:ctrl push up\n  \t  \n# end\n\n"),
  SlateCase(name: "empty file", text: ""),
  // config values
  SlateCase(
    name: "config values",
    text: """
      config defaultToCurrentScreen yes
      config checkDefaultsOnLoad NO
      config focusCheckWidth 1
      config secondsBeforeRepeat 1.5
      config windowHintsFontName 'quoted value'
      config windowHintsFontColor "double quoted"
      config switchFontName value with spaces
      config windowHintsDuration 0x10
      config windowHintsIconAlpha inf
      config windowHintsSpreadPadding -inf
      config windowHintsWidth 1e3
      config windowHintsHeight .5
      config undoMaxStackSize 5.
      config focusCheckWidthMax +3
      config windowHintsRoundedCornerSize ' 5 '
      config nudgePercentOf windowSize
      config resizePercentOf  screenSize
      config repeatOnHoldOps resize,nudge,push
      config keyboardLayout dvorak
      config windowHintsOrder 'none'
      config layoutFocusOnActivate TRUE
      config switchIconSize 0
      config switchShowTitles false
      config secondsBetweenRepet 0.1
      config zzz 1
      config
      config onlyName
      config gridBackgroundColor 75;77;81;1.0
      config switchSelectedPadding 1_000
      config modalEscapeKey esc
      """),
  SlateCase(name: "config NaN", text: "config windowHintsIconAlpha nan\nconfig windowHintsSpread NaN"),
  // bind edge cases
  SlateCase(
    name: "bind edge cases",
    text: """
      bind
      bind a:ctrl
      bind a:ctrl,bogus push up
      bind a:ctrl bogus
      BIND a:ctrl push up
      bind #:ctrl push up
      bind ':ctrl push up # comment with ' quote
      bind a:ctrl shell 'echo # not comment'
      bind\ta:ctrl push up
      binda:ctrl push up
      bind a:ctrl push up#comment
      bind a:ctrl,f4 push left
      bind a:ctrl:toggle push left
      bind ab:ctrl push left
      Bind f13:ctrl,alt,cmd throw next resize
      bind a:ctrl push up extra words here
      bind a:ctrl   chain push up   |   push down
      bind 'a:ctrl push up
      """),
  // layout edge cases
  SlateCase(
    name: "layout edge cases",
    text: """
      layout
      layout l
      layout l 'A'
      layout l 'A':IGNORE_FAIL push up
      layout l A push up
      layout l 'A:B':REPEAT push up
      layout l 'A' push up | push down |
      layout l '' push up
      layout l 'BEFORE' push up
      layout l BEFORE
      layout l AFTER undo
      layout l before undo
      layout l2 'A':TITLE_ORDER=a;b;;c push up
      layout l2 'B':TITLE_ORDER= push up
      layout l2 'C':TITLE_ORDER_REGEX='[a-' push up
      layout l2 'D':TITLE_ORDER_REGEX=^a.*$;b+ push up
      layout l2 'E':ignore_fail,repeat push up
      layout l2 'F':IGNORE_FAIL,,REPEAT push up
      layout l2 'G':'IGNORE_FAIL' push up
      layout l2 'H': push up
      layout 'my layout' 'A' push up
      layout l3 'A' push up | push sideways
      layout l3 'B' 'quoted operation'
      layout l3 BEFORE bogus
      layout l3 AFTER chain push up | push down
      layout l3 'C':TITLE_ORDER_REGEX=(?<name>x)|\\d+ push up
      layout l3 'D':TITLE_ORDER_REGEX=a{2,1} push up
      layout l3 'E':TITLE_ORDER_REGEX=* push up
      layout l3 'F':TITLE_ORDER_REGEX=) push up
      layout l3 'G':MAIN_LAST,MAIN_FIRST,SORT_TITLE,REPEAT_LAST push up
      layout l3 'H':TITLE_ORDER='Inbox — Mail;Drafts' push up
      layout l3 "I":REPEAT push up
      layout l3 'J':UNKNOWN=1,ALSO push up
      """),
  // How strictly TITLE_ORDER_REGEX patterns are checked (ICU's syntax): braces must form a valid interval.
  SlateCase(
    name: "title regex braces",
    text: """
      layout r 'A':TITLE_ORDER_REGEX='a{2' push up
      layout r 'B':TITLE_ORDER_REGEX='a{2}' push up
      layout r 'C':TITLE_ORDER_REGEX='a{2,}' push up
      layout r 'D':TITLE_ORDER_REGEX='a{,2}' push up
      layout r 'E':TITLE_ORDER_REGEX='a{x}' push up
      layout r 'F':TITLE_ORDER_REGEX='{2}' push up
      layout r 'G':TITLE_ORDER_REGEX='a\\{2' push up
      layout r 'H':TITLE_ORDER_REGEX='[{]' push up
      layout r 'I':TITLE_ORDER_REGEX='a}' push up
      layout r 'J':TITLE_ORDER_REGEX='x{2,1}' push up
      layout r 'K':TITLE_ORDER_REGEX='a{2, 3}' push up
      layout r 'L':TITLE_ORDER_REGEX='\\d{3}-\\w+' push up
      layout r 'M':TITLE_ORDER_REGEX='(?<n>a)\\k<n>' push up
      layout r 'N':TITLE_ORDER_REGEX='[a-' push up
      layout r 'O':TITLE_ORDER_REGEX='a\\' push up
      layout r 'P':TITLE_ORDER_REGEX='^Re: (.*)$' push up
      layout r 'Q':TITLE_ORDER_REGEX='a{2}b{3,4}c{5,}' push up
      layout r 'R':TITLE_ORDER_REGEX='a{2}{3}' push up
      layout r 'S':TITLE_ORDER_REGEX='a|b|' push up
      layout r 'T':TITLE_ORDER_REGEX='()' push up
      """),
  // default edge cases
  SlateCase(
    name: "default edge cases",
    text: """
      default l count:0
      default l count:+2
      default l COUNT:2
      default l resolutions:
      default l resolutions:;;
      default l resolutions:1440X900
      default l resolutions:1440x900x1
      default l resolutions:0x900
      default 'a b' count:1
      default l count:2 extra
      default '' count:1
      default l :2
      default l count:-1
      default l count:1.5
      default l resolutions:1440x900;;1920x1080
      default l resolutions:+1440x+900
      default l Resolutions:2560x1440
      default l count:99999999999999999999
      """),
  // source edge cases
  SlateCase(
    name: "source edge cases",
    text: """
      source
      source a b c
      source ~
      source ~/.slate.JS
      source /abs/path.slate
      source rel/../x.slate
      source ./dot.slate
      source ~nobody123/x
      source ~/missing IF_EXISTS
      source ~/self.slate
      source sub//double.slate
      source ~/trailing/
      """,
    files: [
      "/abs/path.slate": "bind a:ctrl push up",
      "\(home)/rel/../x.slate": "bind x:ctrl push down",
      "\(home)/./dot.slate": "bind d:ctrl source ./dot.slate\nsource ./dot.slate\nsource dot.slate",
      "\(home)/self.slate": "source /Users/tester/self.slate\nsource ~/../tester/self.slate",
      "\(home)/sub//double.slate": "bind s:ctrl undo",
      "\(home)/trailing": "bind t:ctrl undo",
      "\(home)/trailing/": "bind u:ctrl undo",
      home: "bind h:ctrl undo",
    ]),
  SlateCase(name: "deeply nested sources", text: "source deep1.slate", files: deepChain),
  SlateCase(
    name: "sources without a path", text: "source ~/.slate\nbind z:ctrl undo", path: nil,
    files: ["\(home)/.slate": "bind y:ctrl undo\nsource ~/.slate"]),
  // aliases
  SlateCase(
    name: "alias edge cases",
    text: """
      alias
      alias a
      alias a b c
      alias x ${b}
      alias y ${
      bind a:ctrl ${}
      alias b push
      alias dir up
      bind a:ctrl ${b} ${dir}
      bind b:ctrl ${b}${dir}
      alias dir down
      bind c:ctrl ${b} ${dir}
      bind d:ctrl push $ up
      bind e:ctrl push ${dir
      alias kw bind
      ${kw} f:ctrl push left
      alias nested ${b} ${dir}
      bind g:ctrl ${nested}
      bind h:ctrl ${nested }
      bind i:ctrl ${Nested}
      bind j:ctrl push ${dir}${dir}
      """),
  SlateCase(
    name: "unknown directives",
    text: "foo bar\nconfig\n# comment\n   # indented\nBIND a:ctrl push up\nDEFAULT l count:2\nAlias q x"),
]

private let stripInputs: [String] = [
  "bind a:ctrl push up # trailing", "bind ':ctrl push up # the ' key", "bind #:ctrl push up", "config a 'b # c' # d",
  "plain line", "# only", "bind\ta:ctrl push up #x", "binda:ctrl push up # x", "shell 'unclosed # quote",
  "BIND x:y z #",
  "bind", "bind ", "bind a#:ctrl push", "x \"#\" # y", "bind \":ctrl push down #\"", "a'b#c'd#e",
]

private let uuidInputs: [String] = [
  "", "a", "hello world", "/Users/tester/.slate\nhyper+a\n\npush up\n0", "é😀", String(repeating: "x", count: 1000),
]

private func fileJ(_ file: SlateConfigFile) -> J {
  [
    "settings": settingsJ(file.settings), "bindings": toJ(file.bindings), "layouts": toJ(file.layouts),
    "defaults": toJ(file.defaults),
    "diagnostics": .array(
      file.diagnostics.map { d in
        var object = toJ(d)
        if case .object(var members) = object {
          members["description"] = .string(d.description)
          object = .object(members)
        }
        return object
      }),
  ]
}

func slateConfigFixtures() -> FixtureFile {
  let parsed: [J] = cases.map { c in
    let result = SlateConfigParser.parse(c.text, path: c.path, homeDirectory: home) { c.files[$0] }
    return [
      "name": .string(c.name), "text": .string(c.text), "path": .optional(c.path), "home": .string(home),
      "files": .object(c.files.mapValues(J.string)), "result": fileJ(result),
    ]
  }
  let strip: [J] = stripInputs.map { ["input": .string($0), "output": .string(SlateConfigParser.stripComment($0))] }
  let uuids: [J] = uuidInputs.map { ["name": .string($0), "uuid": .string(stableUUID($0).uuidString)] }
  return FixtureFile(
    name: "slate-config.json",
    description:
      "Classic .slate files (SlateConfigParser.parse): config/alias/layout/default/bind/source, with diagnostics and "
      + "line numbers. `files` is the in-memory file system for `source` (missing paths can't be read). Bindings, "
      + "layouts and defaults are in Swift's JSON form; each diagnostic also has its `description`.",
    sections: ["parse": parsed, "stripComment": strip, "stableUUID": uuids],
    depth: ["parse": 2])
}
