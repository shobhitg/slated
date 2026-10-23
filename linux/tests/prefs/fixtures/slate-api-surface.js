// Fixture for the preferences importer tests: every query the fake `slate` API answers while a
// binding is probed. The binding throws if any answer has the wrong shape; its final operation
// depends on the screen it runs on, so a correct run imports as a by-orientation pair.

slate.bind("1:ctrl,alt", function (win) {
  var fail = function (what) { throw new Error(what); };

  // The window
  var r = win.rect(), tl = win.tl(), size = win.size();
  if (r.x !== tl.x || r.y !== tl.y || r.width !== size.width || r.height !== size.height) fail("window shapes disagree");
  if (win.title() !== "Window" || win.pid() !== 1) fail("window identity");
  if (win.hidden() || !win.main() || !win.movable() || !win.resizable()) fail("window flags");
  if (win.isMinimizedOrHidden() || !win.isMain() || !win.isMovable() || !win.isResizable()) fail("window flags (long names)");

  // Screens, numbered left to right
  var screens = [];
  S.eachScreen(function (s) {
    screens.push(s.id() + ":" + s.rect().width + "x" + s.rect().height + (s.isMain() ? "*" : "") + "/" + s.vrect().height);
  });
  if (S.screenCount() !== 2 || S.screenc() !== 2) fail("screen count");
  if (screens.join(" ") !== "0:1920x1080*/1055 1:1080x1920/1920") fail("screens: " + screens.join(" "));
  var here = win.screen();
  if (S.screenForRef(String(here.id())).id() !== here.id()) fail("screenForRef by index");
  if (S.screenForRef("next").id() === here.id()) fail("screenForRef next");
  if (S.screenr("previous").id() === here.id()) fail("screenForRef previous");
  if (String(here) !== String(here.id())) fail("screen toString");

  // Apps
  var names = [];
  S.eapp(function (app) { names.push(app.name()); });
  if (names.join() !== "App" || win.app().name() !== "App" || S.app().pid() !== 1 || String(S.app()) !== "App") fail("apps");
  if (S.app().mainWindow().title() !== "Window" || S.app().mwindow().pid() !== 1) fail("main window");

  // Points and rectangles
  if (!S.isPointOffScreen({x: -5, y: 0}) || S.pntoff({x: 10, y: 10})) fail("points");
  if (S.isRectOffScreen({x: 0, y: 0, width: 100, height: 100}) || !S.rectoff({x: -10, y: 0, width: 5, height: 5})) fail("rects");
  if (S.windowUnderPoint({x: 300, y: 300}).title() !== "Window" || S.wup({x: -100, y: -100}) !== undefined) fail("window under point");
  if (S.screenUnderPoint({x: 2000, y: 100}).id() !== 1 || S.sup({x: 10, y: 10}).id() !== 0) fail("screen under point");
  if (S.window().pid() !== 1 || S.screen().id() !== here.id() || S.info.screen().id() !== here.id()) fail("current window and screen");

  // underscore.js, as Slate preloaded it
  var doubled = _.map([1, 2, 3], function (n) { return n * 2; });
  if (_.reduce(doubled, function (a, b) { return a + b; }, 0) !== 12 || _.inject([1, 2], function (a, b) { return a + b; }) !== 3) fail("reduce");
  if (_.filter([1, 2, 3, 4], function (n) { return n % 2; }).join() !== "1,3" || _.reject([1, 2], function (n) { return n > 1; }).join() !== "1") fail("filter");
  if (_.find([4, 5, 6], function (n) { return n > 4; }) !== 5 || !_.some([0, 1]) || _.every([0, 1])) fail("find/some/every");
  if (_.values({a: 1, b: 2}).join() !== "1,2" || _.keys({a: 1}).join() !== "a" || _.size({a: 1, b: 2}) !== 2) fail("objects");
  if (!_.contains([1, 2], 2) || _.pluck([{n: 1}, {n: 2}], "n").join() !== "1,2") fail("contains/pluck");
  if (_.sortBy([3, 1, 2], _.identity).join() !== "1,2,3" || _.first([1, 2, 3]) !== 1 || _.last([1, 2, 3]) !== 3) fail("sortBy/first/last");
  if (_.first([1, 2, 3], 2).join() !== "1,2" || _.last([1, 2, 3], 2).join() !== "2,3" || _.rest([1, 2, 3]).join() !== "2,3") fail("slices");
  if (_.without([1, 2, 1], 1).join() !== "2" || _.uniq([1, 1, 2]).join() !== "1,2" || _.flatten([1, [2, [3]]]).join() !== "1,2,3") fail("arrays");
  if (_.range(3).join() !== "0,1,2" || _.range(1, 7, 2).join() !== "1,3,5" || _.indexOf([5, 6], 6) !== 1) fail("range/indexOf");
  if (_.times(2, function (i) { return i; }).join() !== "0,1" || _.extend({a: 1}, {b: 2}).b !== 2 || _.defaults({a: 1}, {a: 2, b: 3}).a !== 1) fail("times/extend/defaults");
  if (_.clone([1, 2]).length !== 2 || !_.has({a: 1}, "a") || _.bind(function () { return this.x; }, {x: 7})() !== 7) fail("clone/has/bind");
  if (!_.isString("s") || !_.isNumber(1) || !_.isBoolean(false) || !_.isFunction(fail) || !_.isArray([]) || !_.isObject({})) fail("types");
  if (!_.isUndefined(undefined) || !_.isNull(null) || !_.isEmpty([]) || _.isEmpty({a: 1})) fail("emptiness");
  var seen = [];
  _.each({a: 1, b: 2}, function (value, key) { seen.push(key + value); });
  if (seen.join() !== "a1,b2" || _.collect([1], function (n) { return n; }).join() !== "1" || !_.any([1]) || !_.all([1])) fail("each/aliases");

  // The operation depends on the screen's shape: thirds on the wide screen, halves on the tall one.
  var vr = here.vrect();
  win.doop("move", {"x": "screenOriginX", "y": "screenOriginY", "width": "screenSizeX/" + (vr.width > vr.height ? 3 : 2), "height": "screenSizeY"});
});

// Things a config may do while loading, which can't run then.
slate.log("loading");
slate.on("appOpened", function () {});
var nothing = slate.shell("/usr/bin/true", false); // MARK:shell
S.doop("undo"); // MARK:doop

// Sourcing other files
slate.source("~/.slate.extra.js");
slate.source("missing.js"); // MARK:missing
