// Fixture for the preferences importer tests: the corners of Slate's JavaScript API.
// Lines marked "MARK:name" are looked up by the tests, so this file can change without
// renumbering assertions.

"use strict";

// A config's own names may shadow what the importer injects.
let log = [];
const print = (message) => log.push(message);

S.cfga({
  "defaultToCurrentScreen": true,
  "secondsBetweenRepeat": 0.1,
});
S.cfg("orderScreensLeftToRight", true);
slate.config("nudgePercentOf", function () { return "screenSize"; });
slate.config("windowHintsIgnoreHiddenWindows", ["a", "b"]);

// Short aliases and operation objects
var left = S.op("push", {"direction": "left", "style": "bar-resize:screenSizeX/2"});
var right = left.dup({"direction": "right"});
var cycle = S.op("chain", {"operations": [left, right]});
var full = S.op("corner", {"direction": "top-left", "width": "screenSizeX", "height": "screenSizeY"});

S.bnda({
  "1:ctrl,alt": left,
  "2:ctrl,alt": [right, true],
  "3:ctrl,alt": cycle,
});

S.bnd("4:ctrl,alt", {"op": "nudge", "x": "+10%", "y": 0});
S.bnd("5:ctrl,alt", S.op("sequence", {"operations": [[left, full], right]}));

// Operations with function parameters are evaluated when they run.
S.bnd("6:ctrl,alt", S.op("move", {
  "x": "screenOriginX",
  "y": "screenOriginY",
  "width": function () { return slate.screen().rect().width > 1500 ? "screenSizeX/3" : "screenSizeX/2"; },
  "height": "screenSizeY",
}));

// Functions the importer can't express without the script.
S.bnd("7:ctrl,alt", function (win) { win.move({x: 0, y: 0}); });
S.bnd("8:ctrl,alt", function (win) { win.doop(left); win.doop(right); });
S.bnd("9:ctrl,alt", function (win) { slate.log("nothing to do"); });
S.bnd("0:ctrl,alt", function (win) { throw new Error("boom"); });
S.bnd("f1:ctrl", function (win) { slate.shell("/usr/bin/true", false); });

// Functions that do exactly one thing convert.
S.bnd("f2:ctrl", function (win) { win.doop("focus", {"direction": "left"}); });
S.bnd("f3:ctrl", function () { slate.doOperation(full); });
S.bnd("f4:ctrl", (win) => {
  var r = S.window().screen().rect();
  win.doOperation(r.height > r.width ? right : left);
});

// Modal keys: press ctrl+alt+f6, then the key.
S.bnd("m:f6,ctrl,alt", left);
S.bnd("n:ctrl,alt,f6:toggle", right);

// Mistakes are reported with their line, and the rest of the file still loads.
var bogus = slate.operation("teleport", {"to": "mars"}); // MARK:unknown-op
var broken = slate.operation("push", {"style": "bar"}); // MARK:invalid-op
var ignored = slate.operation("move", {"x": 0, "y": 0, "width": 10, "height": 10, "depth": 3}); // MARK:unknown-param
slate.bind("1:ctrl,alt", right); // MARK:duplicate

// Layouts: static ones import, ones with JavaScript stay in the script.
slate.layout("coding", {
  "_before_": {"operations": [S.op("hide", {"app": "all-but:Terminal"})]},
  "Firefox": {"operations": [left], "ignore-fail": true, "repeat": true},
  "Terminal": {"operations": [right, full], "title-order": "one;two"},
});
slate.layout("scripted", {
  "Files": {"operations": [function (win) { win.move({x: 1, y: 1}); }]},
});
slate.default(2, "coding");

// underscore.js was preloaded in Slate.
_.each(["k", "l"], function (key, index) {
  S.bnd(key + ":cmd,shift", index === 0 ? left : right);
});

// Bindings that don't use Hyper
S.bnd("space:ctrl;cmd", full);
