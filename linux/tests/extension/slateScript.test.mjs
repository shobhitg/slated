import assert from 'node:assert/strict';
import {existsSync, readFileSync} from 'node:fs';
import {homedir} from 'node:os';
import {dirname, join} from 'node:path';
import {test} from 'node:test';
import {fileURLToPath} from 'node:url';

import {SlateScriptEngine, coerceParameter, functionFrameLine, normalizeAction, staticLayout} from '../../gnome-extension/lib/platform/slateScript.js';
import {fakeCore, realCore} from './fake-core.mjs';
import {FakeHost, LANDSCAPE_WINDOW, PORTRAIT_WINDOW} from './fake-host.mjs';

const repo = join(dirname(fileURLToPath(import.meta.url)), '../../..');

function engineWith(source, {files = {}, core = fakeCore, host = new FakeHost()} = {}) {
  const readFile = (path) => (path in files ? files[path] : null);
  const engine = new SlateScriptEngine({host, core, readFile, home: '/home/me'});
  const result = engine.loadSource(source, '/home/me/.slate.js');
  return {engine, host, result};
}

const bindingFor = (result, id) => result.bindings.find((b) => b.id === id);

/** Invokes a binding with the focus on `window` and returns the actions the host performed. */
function invokeOn(engine, host, binding, window) {
  host.reset();
  host.focused = window;
  const outcome = engine.invoke(binding);
  return {outcome, actions: host.performed.map((p) => p.action), windows: host.performed.map((p) => p.window)};
}

// --- The repo's smoke-test fixture --------------------------------------------------------------------

test('the smoke fixture loads its four bindings, with orientation logic working', () => {
  const source = readFileSync(join(repo, 'Tests/Smoke/fixtures/slate.js'), 'utf8');
  const {engine, host, result} = engineWith(source);
  assert.deepEqual(result.diagnostics, []);
  assert.deepEqual(result.bindings.map((b) => b.id), ['hyper+a', 'hyper+w', 'hyper+f', 'hyper+tab']);
  assert.ok(result.bindings.every((b) => b.target.kind === 'callback' && b.summary === 'JavaScript function'));

  const left = invokeOn(engine, host, bindingFor(result, 'hyper+a'), LANDSCAPE_WINDOW);
  assert.equal(left.outcome.success, true);
  assert.deepEqual(left.actions, [{op: 'move', x: 'screenOriginX', y: 'screenOriginY', width: 'screenSizeX/2', height: 'screenSizeY'}]);
  assert.deepEqual(left.windows, [LANDSCAPE_WINDOW]);

  const top = invokeOn(engine, host, bindingFor(result, 'hyper+w'), LANDSCAPE_WINDOW);
  assert.deepEqual(top.actions, [{op: 'push', direction: 'up', style: 'bar-resize:screenSizeY/2'}]);

  const wide = invokeOn(engine, host, bindingFor(result, 'hyper+f'), LANDSCAPE_WINDOW);
  assert.deepEqual(wide.actions, [{op: 'push', direction: 'left'}]);
  const tall = invokeOn(engine, host, bindingFor(result, 'hyper+f'), PORTRAIT_WINDOW);
  assert.deepEqual(tall.actions, [{op: 'corner', direction: 'top-left'}]);

  const grid = invokeOn(engine, host, bindingFor(result, 'hyper+tab'), LANDSCAPE_WINDOW);
  assert.deepEqual(grid.actions, [{op: 'grid', padding: 4, grids: {0: {width: 6, height: 6}, 1: {width: 6, height: 6}}}]);
});

// --- The author's config, in miniature (same constructs as ~/.slate.js) ---------------------------------

const authorStyle = `
// Create Operations
let tophalf = slate.operation("push", {
  "direction" : "bottom",
  "style" : "bar-resize:screenSizeY/2"
});
let topleft = slate.operation("corner", {
  "direction" : "top-left",
  "width" : "screenSizeX/2",
  "height" : "screenSizeY/2",
});
let horizontalonethird1 = slate.operation("move", {
    "x": "screenOriginX",
    "y": "screenOriginY",
    "width": "screenSizeX/3",
    "height": "screenSizeY",
  });
let verticalonethird1 = slate.operation("move", {
    "x": "screenOriginX",
    "y": "screenOriginY",
    "width": "screenSizeX",
    "height": "screenSizeY/3",
  });

slate.bind("x:ctrl,shift,alt,cmd", (win) => {
    win.doOperation(tophalf);
});
slate.bind("q:ctrl,shift,alt,cmd", (win) => {
    win.doOperation(topleft);
});
slate.bind("f:ctrl,shift,alt,cmd", (win) => {
    let rect = slate.screen().rect();
    let isHorizontalScreen = rect.width > rect.height;
    if (isHorizontalScreen) {
        win.doOperation(horizontalonethird1);
    } else {
        win.doOperation(verticalonethird1);
    }
});
slate.bind("':ctrl,shift,alt,cmd", (win) => {
    win.doOperation(slate.operationFromString("push top bar-resize:screenSizeY/2"));
});
slate.bind("down:ctrl,shift,alt,cmd", (win) => {
    win.doOperation(slate.operationFromString("throw 1  resize"));
});
`;

test('an author-style config: operations, orientation checks and win.doOperation', () => {
  const {engine, host, result} = engineWith(authorStyle);
  assert.deepEqual(result.diagnostics, []);
  assert.deepEqual(result.bindings.map((b) => b.id), ['hyper+x', 'hyper+q', 'hyper+f', "hyper+'", 'hyper+down']);

  assert.deepEqual(invokeOn(engine, host, bindingFor(result, 'hyper+x'), LANDSCAPE_WINDOW).actions, [
    {op: 'push', direction: 'down', style: 'bar-resize:screenSizeY/2'},
  ]);
  assert.deepEqual(invokeOn(engine, host, bindingFor(result, 'hyper+q'), LANDSCAPE_WINDOW).actions, [
    {op: 'corner', direction: 'top-left', width: 'screenSizeX/2', height: 'screenSizeY/2'},
  ]);
  assert.deepEqual(invokeOn(engine, host, bindingFor(result, 'hyper+f'), LANDSCAPE_WINDOW).actions, [
    {op: 'move', x: 'screenOriginX', y: 'screenOriginY', width: 'screenSizeX/3', height: 'screenSizeY'},
  ]);
  assert.deepEqual(invokeOn(engine, host, bindingFor(result, 'hyper+f'), PORTRAIT_WINDOW).actions, [
    {op: 'move', x: 'screenOriginX', y: 'screenOriginY', width: 'screenSizeX', height: 'screenSizeY/3'},
  ]);
  assert.deepEqual(invokeOn(engine, host, bindingFor(result, "hyper+'"), LANDSCAPE_WINDOW).actions, [
    {op: 'push', direction: 'up', style: 'bar-resize:screenSizeY/2'},
  ]);
  assert.deepEqual(invokeOn(engine, host, bindingFor(result, 'hyper+down'), PORTRAIT_WINDOW).actions, [
    {op: 'throw', screen: '1', width: 'screenSizeX', height: 'screenSizeY'},
  ]);
});

// --- The real ~/.slate.js, when there is one (the acceptance case; like StarterTests on macOS) ----------

const authorConfig = join(homedir(), '.slate.js');

test('~/.slate.js loads completely and every binding performs one operation', {skip: !existsSync(authorConfig) && 'no ~/.slate.js'}, () => {
  const core = realCore() ?? fakeCore;
  const host = new FakeHost();
  const engine = new SlateScriptEngine({host, core, readFile: (p) => (existsSync(p) ? readFileSync(p, 'utf8') : null), home: homedir()});
  const result = engine.load(authorConfig);
  assert.deepEqual(result.diagnostics, [], 'no diagnostics');
  assert.equal(result.bindings.length, 21);
  for (const binding of result.bindings) {
    for (const window of [LANDSCAPE_WINDOW, PORTRAIT_WINDOW]) {
      const {outcome, actions} = invokeOn(engine, host, binding, window);
      assert.equal(outcome.success, true, `${binding.id} runs`);
      assert.equal(actions.length, 1, `${binding.id} performs one operation`);
    }
  }
  // Thirds follow the screen's shape.
  const thirds = bindingFor(result, 'hyper+f');
  assert.equal(invokeOn(engine, host, thirds, LANDSCAPE_WINDOW).actions[0].width, 'screenSizeX/3');
  assert.equal(invokeOn(engine, host, thirds, PORTRAIT_WINDOW).actions[0].height, 'screenSizeY/3');
});

// --- Diagnostics -------------------------------------------------------------------------------------

test('runtime errors in a bound function report the script line', () => {
  const {engine, host, result} = engineWith(['slate.bind("a:ctrl", function (win) {', '  win.doOperation("push", {direction: "left"});', '  missingFunction();', '});'].join('\n'));
  assert.deepEqual(result.diagnostics, []);
  const outcome = engine.invoke(result.bindings[0]);
  assert.equal(outcome.success, false);
  assert.equal(outcome.diagnostics.length, 1);
  assert.match(outcome.diagnostics[0].message, /missingFunction/);
  assert.equal(outcome.diagnostics[0].line, 3);
  assert.equal(outcome.diagnostics[0].file, '/home/me/.slate.js');
  assert.equal(host.performed.length, 1, 'what ran before the error still ran');
});

test('a load-time exception reports its line and keeps earlier bindings', () => {
  const {result} = engineWith(['slate.bind("a:ctrl", "push left");', '', 'null.boom;', 'slate.bind("b:ctrl", "push right");'].join('\n'));
  assert.equal(result.bindings.length, 1);
  assert.equal(result.hasErrors, true);
  assert.equal(result.diagnostics[0].line, 3);
  assert.match(result.diagnostics[0].message, /TypeError/);
});

test('API misuse is reported at the calling line; a failed operation isn’t reported twice', () => {
  const {result} = engineWith(
    [
      'slate.bind("a:ctrl", slate.operation("teleport", {}));',
      'var op = slate.operation("push", {direction: "left", sideways: true});',
      'slate.bind("nope:ctrl", op);',
      'slate.bind("b:ctrl", 42);',
      'slate.bind("c:ctrl", "push left");',
      'slate.bind("c:ctrl", "push right");',
    ].join('\n'),
  );
  const brief = result.diagnostics.map((d) => [d.severity, d.line, d.message]);
  assert.deepEqual(brief, [
    ['error', 1, 'Unknown operation "teleport".'],
    ['warning', 2, '"push" has no parameter "sideways", so it was ignored.'],
    ['error', 3, 'Can\'t bind "nope:ctrl": Unknown key "nope" in "nope:ctrl"'],
    ['error', 4, 'slate.bind("b:ctrl", …) needs an operation or a function, got the number 42.'],
    ['warning', 6, '"c:ctrl" is bound more than once (first on line 5).'],
  ]);
  assert.deepEqual(result.bindings.map((b) => b.id), ['ctrl+c', 'ctrl+c']);
});

test('a syntax error is an error diagnostic, not an exception', () => {
  const {result} = engineWith('slate.bind("a:ctrl", function (win) {');
  assert.equal(result.bindings.length, 0);
  assert.equal(result.hasErrors, true);
  assert.match(result.diagnostics[0].message, /SyntaxError/);
});

test('stack frames from new Function code are located in both engines', () => {
  assert.equal(functionFrameLine('anonymous@file:///x/slateScript.js line 412 > Function:12:9\n@file:///x/a.js:1:1'), 12);
  assert.equal(functionFrameLine('Error\n    at eval (eval at evaluate (file:///x/slateScript.js:412:12), <anonymous>:7:3)'), 7);
  assert.equal(functionFrameLine('Error\n    at foo (file:///x/slateScript.js:10:3)'), null);
});

// --- Settings, bindings, operations --------------------------------------------------------------------

test('config and configAll, including functions and lists', () => {
  const {engine, result} = engineWith(
    [
      'slate.config("defaultToCurrentScreen", true);',
      'slate.configAll({nudgePercentOf: "windowSize", undoMaxStackSize: 5, repeatOnHoldOps: ["move", "resize"]});',
      'var n = 1;',
      'slate.config("secondsBetweenRepeat", function () { return n / 10; });',
      'slate.bind("m:ctrl", slate.operation("move", {x: 0, y: 0, width: 10, height: 10}));',
      'slate.bind("p:ctrl", "push left");',
      'slate.bind("r:ctrl", "push left", true);',
      'n = 3;',
    ].join('\n'),
  );
  assert.deepEqual(result.settings, {
    defaultToCurrentScreen: true,
    nudgePercentOf: 'windowSize',
    undoMaxStackSize: 5,
    repeatOnHoldOps: 'move;resize',
    secondsBetweenRepeat: 0.3,
  });
  assert.equal(engine.evaluatedSettings().secondsBetweenRepeat, 0.3);
  // repeatOnHoldOps is "move;resize" here (Slate joined lists with ;), so only explicit repeats apply.
  assert.deepEqual(result.bindings.map((b) => [b.id, b.repeats]), [
    ['ctrl+m', false],
    ['ctrl+p', false],
    ['ctrl+r', true],
  ]);
  assert.deepEqual(result.bindings[0].target, {kind: 'action', action: {op: 'move', x: '0', y: '0', width: '10', height: '10'}});
});

test('repeatOnHoldOps decides which bindings repeat while held', () => {
  const {result} = engineWith(['slate.config("repeatOnHoldOps", "push,nudge");', 'slate.bind("a:ctrl", "push left");', 'slate.bind("b:ctrl", "focus left");'].join('\n'));
  assert.deepEqual(result.bindings.map((b) => b.repeats), [true, false]);
});

test('bindAll, aliases and modal keystrokes', () => {
  const {result} = engineWith(
    [
      'S.bnda({',
      '  "a:ctrl": S.op("push", {direction: "left"}),',
      '  "b:ctrl": [S.opstr("push right"), true],',
      '  "1:f4,ctrl,alt": "push up",',
      '});',
    ].join('\n'),
  );
  assert.deepEqual(result.diagnostics, []);
  assert.deepEqual(result.bindings.map((b) => [b.id, b.repeats]), [
    ['ctrl+a', false],
    ['ctrl+b', true],
    ['ctrl+alt+f4 1', false],
  ]);
  assert.deepEqual(result.bindings[2].modal, {keys: {key: 'f4', modifiers: ['ctrl', 'alt']}, toggle: false});
});

test('dup copies an operation with changed parameters', () => {
  const {result} = engineWith(
    [
      'var half = slate.operation("move", {x: "screenOriginX", y: "screenOriginY", width: "screenSizeX/2", height: "screenSizeY"});',
      'slate.bind("a:ctrl", half.dup({width: "screenSizeX/3"}));',
      'slate.bind("b:ctrl", slate.operationFromString("push left").dup({style: "bar"}));',
    ].join('\n'),
  );
  assert.deepEqual(result.diagnostics, []);
  assert.equal(result.bindings[0].target.action.width, 'screenSizeX/3');
  assert.deepEqual(result.bindings[1].target.action, {op: 'push', direction: 'left', style: 'bar'});
});

test('chains and sequences of plain operations become plain actions', () => {
  const {result} = engineWith(
    [
      'slate.bind("a:ctrl", slate.operation("chain", {operations: ["push left", {op: "push", direction: "right"}]}));',
      'slate.bind("b:ctrl", slate.operation("sequence", {operations: ["push left", ["focus right", "push right"]]}));',
    ].join('\n'),
  );
  assert.deepEqual(result.diagnostics, []);
  assert.deepEqual(result.bindings[0].target.action, {
    op: 'chain',
    operations: [
      {op: 'push', direction: 'left'},
      {op: 'push', direction: 'right'},
    ],
  });
  assert.deepEqual(result.bindings[1].target.action, {
    op: 'sequence',
    steps: [
      {action: {op: 'push', direction: 'left'}, keepWindow: false},
      {action: {op: 'focus', direction: 'right'}, keepWindow: false},
      {action: {op: 'push', direction: 'right'}, keepWindow: true},
    ],
  });
});

test('chains with JavaScript cycle per window', () => {
  const {engine, host, result} = engineWith(
    ['var calls = [];', 'slate.bind("a:ctrl", slate.operation("chain", {operations: [function (w) { slate.log("first", w.title()); }, "push right"]}));'].join('\n'),
  );
  const binding = result.bindings[0];
  assert.equal(binding.summary, 'chain (with JavaScript)');
  invokeOn(engine, host, binding, LANDSCAPE_WINDOW);
  assert.deepEqual(host.logs, ['first Mail']);
  assert.deepEqual(invokeOn(engine, host, binding, LANDSCAPE_WINDOW).actions, [{op: 'push', direction: 'right'}]);
  invokeOn(engine, host, binding, PORTRAIT_WINDOW);
  assert.deepEqual(host.logs, ['first Docs'], 'another window starts the chain over');
});

test('operations with function parameters are evaluated when they run', () => {
  const {engine, host, result} = engineWith(['var w = "screenSizeX/2";', 'slate.bind("a:ctrl", slate.operation("move", {x: 0, y: 0, width: function () { return w; }, height: 100}));', 'w = "screenSizeX/4";'].join('\n'));
  const {actions} = invokeOn(engine, host, result.bindings[0], LANDSCAPE_WINDOW);
  assert.deepEqual(actions, [{op: 'move', x: '0', y: '0', width: 'screenSizeX/4', height: '100'}]);
});

test('windows, apps and screens from scripts', () => {
  const {engine, host, result} = engineWith(
    [
      'slate.bind("a:ctrl", function (win) {',
      '  slate.log(JSON.stringify(win.rect()), JSON.stringify(win.tl()), JSON.stringify(win.size()), win.title(), win.pid());',
      '  slate.log(win.app().name(), win.screen().id(), slate.screenCount(), win.isMain(), win.movable());',
      '  slate.log(JSON.stringify(slate.screen().vrect()), slate.window().title(), slate.app().name());',
      '  slate.eachScreen(function (s) { slate.log("screen", s.id(), JSON.stringify(s.rect())); });',
      '  slate.eachApp(function (app) { slate.log("app", app.name(), app.pid()); });',
      '  slate.log(slate.screenForRef("right").id(), slate.isPointOffScreen({x: -5, y: 5}), slate.isRectOffScreen({x: 0, y: 0, width: 50, height: 50}));',
      '  slate.log(slate.windowUnderPoint({x: 2200, y: 400}).title(), slate.screenUnderPoint({x: 10, y: 10}).isMain());',
      '  win.move({x: "screenOriginX+10", y: 50});',
      '  win.resize({width: "screenSizeX/2", height: 200});',
      '}',
      ');',
    ].join('\n'),
  );
  assert.deepEqual(result.diagnostics, []);
  const outcome = engine.invoke(result.bindings[0]);
  assert.deepEqual(outcome.diagnostics, []);
  assert.deepEqual(host.logs, [
    '{"x":100,"y":100,"width":800,"height":600} {"x":100,"y":100} {"width":800,"height":600} Mail 10',
    'Firefox 0 2 true true',
    '{"x":0,"y":32,"width":1920,"height":1048} Mail Firefox',
    'screen 0 {"x":0,"y":0,"width":1920,"height":1080}',
    'screen 1 {"x":1920,"y":0,"width":1080,"height":1920}',
    'app Firefox 10',
    'app Files 20',
    '1 true false',
    'Docs true',
  ]);
  assert.deepEqual(host.frames, [
    [LANDSCAPE_WINDOW, {x: 10, y: 50, width: 800, height: 600}],
    [LANDSCAPE_WINDOW, {x: 10, y: 50, width: 960, height: 200}],
  ]);
});

test('app.eachWindow runs an operation on each window of the app', () => {
  const {engine, host, result} = engineWith('slate.bind("a:ctrl", function (win) { win.app().eachWindow("push left"); slate.app().ewindow(function (w) { slate.log(w.title()); }); });');
  invokeOn(engine, host, result.bindings[0], PORTRAIT_WINDOW);
  assert.deepEqual(host.performed, [{action: {op: 'push', direction: 'left'}, window: PORTRAIT_WINDOW}]);
  assert.deepEqual(host.logs, ['Docs']);
});

test('slate.shell and slate.log reach the host', () => {
  const {host, result} = engineWith('var out = slate.shell("echo hi", true, "~/src"); slate.log("got", out.trim()); slate.sh("touch x");');
  assert.deepEqual(result.diagnostics, []);
  assert.deepEqual(host.shells, [
    {command: 'echo hi', wait: true, path: '/home/me/src'},
    {command: 'touch x', wait: false, path: null},
  ]);
  assert.deepEqual(host.logs, ['got output']);
});

// --- Layouts, defaults, events, sourcing ----------------------------------------------------------------

test('layouts keep Slate’s per-app options; plain ones become config layouts', () => {
  const {result} = engineWith(
    [
      'slate.layout("plain", {',
      '  "_before_": {operations: "hide all-but:Terminal"},',
      '  "Terminal": {operations: ["push left", "push right"], repeat: true, "title-order": "a;b", "ignore-fail": 1},',
      '});',
      'slate.layout("scripted", {"Firefox": {operations: [function (w) {}], "main-first": true}});',
      'slate.layout("empty", {"Files": {}});',
    ].join('\n'),
    {core: {...fakeCore, parseOperation: (text) => (text.startsWith('hide') ? {op: 'hide', app: 'all-but:Terminal'} : fakeCore.parseOperation(text))}},
  );
  assert.deepEqual(
    result.diagnostics.map((d) => d.message),
    ['Layout "empty": "Files" has no "operations", so it was skipped.'],
  );
  const plain = staticLayout(result.layouts[0]);
  assert.deepEqual(plain, {
    name: 'plain',
    before: [{op: 'hide', app: 'all-but:Terminal'}],
    after: [],
    apps: [
      {
        app: 'Terminal',
        operations: [
          {op: 'push', direction: 'left'},
          {op: 'push', direction: 'right'},
        ],
        options: {ignoreFail: true, repeat: true, repeatLast: false, mainFirst: false, mainLast: false, sortTitle: false, titleOrder: ['a', 'b']},
      },
    ],
  });
  assert.equal(staticLayout(result.layouts[1]), null);
  assert.equal(result.layouts[1].apps[0].options.mainFirst, true);
});

test('display defaults accept counts, resolution lists and functions', () => {
  const {result} = engineWith(
    [
      'slate.default(2, "plain");',
      'slate.default("1920x1080;1080x1920", function () {});',
      'slate.default(["1080x1920", "1920x1080"], slate.operation("layout", {name: "work"}));',
      'slate.default({}, "x");',
    ].join('\n'),
  );
  assert.deepEqual(result.defaults[0], {condition: {count: 2}, target: {name: 'plain'}});
  assert.deepEqual(result.defaults[1].condition, {resolutions: ['1080x1920', '1920x1080']});
  assert.equal(typeof result.defaults[1].target.callback, 'number');
  assert.deepEqual(result.defaults[2], {condition: {resolutions: ['1080x1920', '1920x1080']}, target: {name: 'work'}});
  assert.equal(result.diagnostics.length, 1);
});

test('slate.on registers handlers that receive Slate’s payloads', () => {
  const {engine, host, result} = engineWith(
    [
      'slate.on("appActivated", function (event, app) { slate.log(event, app.name()); });',
      'slate.on("windowFocused", function (event, win) { slate.log(event, win.title()); });',
      'slate.on("screenConfigurationChanged", function (event, nothing) { slate.log(event, typeof nothing); });',
      'slate.on("windowTeleported", function () {});',
    ].join('\n'),
  );
  assert.deepEqual(result.events.sort(), ['appActivated', 'screenConfigurationChanged', 'windowFocused']);
  assert.match(result.diagnostics[0].message, /doesn't know the event the string "windowTeleported"/);
  engine.dispatch({name: 'appActivated', app: {pid: 20, name: 'Files'}});
  engine.dispatch({name: 'windowFocused', window: PORTRAIT_WINDOW});
  engine.dispatch({name: 'screenConfigurationChanged'});
  assert.deepEqual(host.logs, ['appActivated Files', 'windowFocused Docs', 'screenConfigurationChanged undefined']);
});

test('a throwing event handler fails that dispatch only', () => {
  const {engine, host, result} = engineWith(['slate.on("appClosed", function () { throw new Error("nope"); });', 'slate.on("appClosed", function (e, app) { slate.log("still", app.name()); });'].join('\n'));
  assert.equal(result.hasErrors, false);
  const outcome = engine.dispatch({name: 'appClosed', app: {pid: 10, name: 'Firefox'}});
  assert.equal(outcome.success, false);
  assert.match(outcome.diagnostics[0].message, /nope/);
  assert.deepEqual(host.logs, ['still Firefox']);
});

test('slate.source loads JavaScript and classic files relative to home, without loops', () => {
  const files = {
    '/home/me/extra.js': 'slate.bind("e:ctrl", "push right"); slate.source("~/.slate.js");',
    '/home/me/.slate.classic': 'config defaultToCurrentScreen true\nbind s:ctrl;cmd push left\n',
  };
  const {result} = engineWith(['slate.source("extra.js");', 'slate.source("~/.slate.classic");', 'slate.source("~/missing.js");'].join('\n'), {files});
  assert.deepEqual(result.bindings.map((b) => [b.id, b.file]), [
    ['ctrl+e', '/home/me/extra.js'],
    ['ctrl+cmd+s', '/home/me/.slate.classic'],
  ]);
  assert.equal(result.settings.defaultToCurrentScreen, true);
  assert.deepEqual(result.sourcedFiles, ['/home/me/extra.js', '/home/me/.slate.classic']);
  assert.deepEqual(
    result.diagnostics.map((d) => d.message),
    ['~/.slate.js is already loading, so slate.source skipped it to avoid a loop.', "Couldn't read ~/missing.js, so slate.source skipped it."],
  );
});

test('a sourced classic file’s display defaults keep their condition', () => {
  const files = {'/home/me/.slate.classic': 'default coding count:2\ndefault big resolutions:1920x1080;2560x1440\n'};
  const {result} = engineWith('slate.source("~/.slate.classic");', {files, core: realCore()});
  assert.deepEqual(result.diagnostics, []);
  assert.deepEqual(result.defaults, [
    {condition: {count: 2}, target: {name: 'coding'}},
    {condition: {resolutions: ['1920x1080', '2560x1440']}, target: {name: 'big'}},
  ]);
});

test('slate.bind after loading is ignored with a warning', () => {
  const {engine, result} = engineWith('var late = function () { slate.bind("z:ctrl", "push left"); }; slate.bind("a:ctrl", late);');
  const outcome = engine.invoke(result.bindings[0]);
  assert.equal(outcome.success, true);
  assert.match(outcome.diagnostics[0].message, /only works while the config loads/);
  assert.equal(engine.result.bindings.length, 1);
});

test('underscore basics are available as _', () => {
  const {host} = engineWith(
    [
      'slate.log(_.map([1, 2, 3], function (x) { return x * 2; }).join(","));',
      'slate.log(_.filter({a: 1, b: 2}, function (v) { return v > 1; }).join(","));',
      'slate.log(_.keys({x: 1, y: 2}).join(","), _.size([1, 2]), _.isEmpty({}), _.range(3).join(""));',
      'slate.log(window === this, typeof window.slate);',
    ].join('\n'),
  );
  assert.deepEqual(host.logs, ['2,4,6', '2', 'x,y 2 true 012', 'true object']);
});

// --- Keeping GNOME Shell's global object clean ----------------------------------------------------------

test('names assigned without let leak into the global object: warned about and removed on reload', () => {
  const {engine, result} = engineWith('slatedLeakedForTest = slate.operation("push", {direction: "left"}); slate.bind("a:ctrl", slatedLeakedForTest);');
  assert.equal(result.bindings.length, 1);
  assert.match(result.diagnostics[0].message, /"slatedLeakedForTest" was assigned without let/);
  assert.equal(result.diagnostics[0].severity, 'warning');
  assert.ok('slatedLeakedForTest' in globalThis);
  engine.loadSource('// nothing', '/home/me/.slate.js');
  assert.ok(!('slatedLeakedForTest' in globalThis));
});

test('overwriting an existing global is undone', () => {
  globalThis.slatedProtectedForTest = 'original';
  try {
    const {result} = engineWith('slatedProtectedForTest = "replaced";');
    assert.equal(globalThis.slatedProtectedForTest, 'original');
    assert.match(result.diagnostics[0].message, /replaced GNOME Shell's global "slatedProtectedForTest"/);
  } finally {
    delete globalThis.slatedProtectedForTest;
  }
});

test('non-enumerable globals appearing during a run (lazy standard classes) are left alone', () => {
  try {
    const {engine, result} = engineWith('Object.defineProperty(globalThis, "slatedLazyForTest", {value: 1, enumerable: false, configurable: true});');
    assert.deepEqual(result.diagnostics, []);
    engine.destroy();
    assert.equal(globalThis.slatedLazyForTest, 1);
  } finally {
    delete globalThis.slatedLazyForTest;
  }
});

test('destroy removes leaked globals too', () => {
  const {engine} = engineWith('slatedLeakedTwice = 1;');
  assert.ok('slatedLeakedTwice' in globalThis);
  engine.destroy();
  assert.ok(!('slatedLeakedTwice' in globalThis));
});

// --- Pieces ---------------------------------------------------------------------------------------------

test('parameters are coerced like Slate’s Objective-C reads', () => {
  assert.equal(coerceParameter('yes', 'wait'), true);
  assert.equal(coerceParameter('0', 'save'), false);
  assert.equal(coerceParameter(2, 'stack'), true);
  assert.equal(coerceParameter(' 4 ', 'padding'), 4);
  assert.deepEqual(coerceParameter({0: {width: '6', height: 3}}, 'grids'), {0: {width: 6, height: 3}});
  assert.equal(coerceParameter('x', 'name'), 'x');
});

test('normalizeAction uses the core decoder and strips its wrapper path from errors', () => {
  assert.deepEqual(normalizeAction(fakeCore, {op: 'push', direction: 'top'}), {op: 'push', direction: 'up'});
  assert.throws(() => normalizeAction(fakeCore, {op: 'teleport'}), {message: 'Unknown operation "teleport"'});
});

test('with the real core (once implemented) the smoke fixture behaves the same', {skip: !realCore() && 'lib/core is still the stub'}, () => {
  const core = realCore();
  const source = readFileSync(join(repo, 'Tests/Smoke/fixtures/slate.js'), 'utf8');
  const {engine, host, result} = engineWith(source, {core});
  assert.deepEqual(result.diagnostics, []);
  assert.equal(result.bindings.length, 4);
  const wide = invokeOn(engine, host, bindingFor(result, 'hyper+f'), LANDSCAPE_WINDOW);
  const tall = invokeOn(engine, host, bindingFor(result, 'hyper+f'), PORTRAIT_WINDOW);
  assert.equal(wide.actions[0].op, 'push');
  assert.equal(tall.actions[0].op, 'corner');
});
