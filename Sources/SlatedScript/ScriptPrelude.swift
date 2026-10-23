import Foundation

/// JavaScript that turns the engine's native functions into Slate's API: the `slate`/`S` objects
/// with their short aliases, and the operation, window, application and screen classes.
///
/// It evaluates to a function that takes the global object and the native functions, installs the
/// globals, and returns the classes so Swift can create instances. The native functions stay private
/// to this closure; scripts only see `slate`, `S`, `window` and `_`.
enum ScriptPrelude {
  static let sourceURL = URL(string: "slated://prelude.js")!

  static let source = #"""
    (function (global, native) {
      "use strict";

      function defineHidden(object, key, value) {
        Object.defineProperty(object, key, { value: value });
      }

      // Slate's short names, e.g. `S.op` for `S.operation` or `win.tl()` for `win.topLeft()`.
      function addAliases(target, aliases, enumerable) {
        for (const short of Object.keys(aliases)) {
          Object.defineProperty(target, short, {
            value: target[aliases[short]], enumerable: !!enumerable, writable: true, configurable: true,
          });
        }
      }

      class SlateOperation {
        constructor(name) {
          Object.defineProperty(this, "name", { value: name, enumerable: true });
        }
        run() { return native.runOperation(this); }
        dup(params) { return native.dupOperation(this, params); }
        toString() { return "[SlateOperation " + this.name + "]"; }
      }

      class SlateWindow {
        constructor(handle) { defineHidden(this, "__handle", handle); }
        title() { return native.windowTitle(this.__handle); }
        topLeft() { return native.windowTopLeft(this.__handle); }
        size() { return native.windowSize(this.__handle); }
        rect() { return native.windowRect(this.__handle); }
        pid() { return native.windowPid(this.__handle); }
        focus() { return native.windowFocus(this.__handle); }
        isMinimizedOrHidden() { return native.windowFlag(this.__handle, "minimizedOrHidden"); }
        isMain() { return native.windowFlag(this.__handle, "main"); }
        isMovable() { return native.windowFlag(this.__handle, "movable"); }
        isResizable() { return native.windowFlag(this.__handle, "resizable"); }
        move(point) { return native.windowMove(this.__handle, point); }
        resize(size) { return native.windowResize(this.__handle, size); }
        screen() { return native.windowScreen(this.__handle); }
        app() { return native.windowApp(this.__handle); }
        doOperation(operation, params) { return native.windowDoOperation(this.__handle, operation, params); }
      }
      addAliases(SlateWindow.prototype, {
        tl: "topLeft", hidden: "isMinimizedOrHidden", main: "isMain", movable: "isMovable",
        resizable: "isResizable", doop: "doOperation",
      });

      class SlateApplication {
        constructor(pid, name) {
          defineHidden(this, "__pid", pid);
          defineHidden(this, "__name", name);
        }
        pid() { return this.__pid; }
        name() { return native.appName(this.__pid, this.__name); }
        eachWindow(callback) { return native.appEachWindow(this.__pid, callback); }
        mainWindow() { return native.appMainWindow(this.__pid); }
        toString() { return String(this.name()); }
      }
      addAliases(SlateApplication.prototype, { ewindow: "eachWindow", mwindow: "mainWindow" });

      class SlateScreen {
        constructor(id) { defineHidden(this, "__id", id); }
        id() { return this.__id; }
        rect() { return native.screenRect(this.__id, false); }
        visibleRect() { return native.screenRect(this.__id, true); }
        isMain() { return native.screenIsMain(this.__id); }
        toString() { return String(this.__id); }
      }
      addAliases(SlateScreen.prototype, { vrect: "visibleRect", main: "isMain" });

      // Questions about windows, apps and screens. Slate offers them as `S.info` and directly on `S`.
      const info = {
        window() { return native.currentWindow(); },
        app() { return native.currentApp(); },
        screen() { return native.currentScreen(); },
        eachApp(callback) { return native.eachApp(callback); },
        windowUnderPoint(point) { return native.windowUnderPoint(point); },
        screenUnderPoint(point) { return native.screenUnderPoint(point); },
        isRectOffScreen(rect) { return native.isRectOffScreen(rect); },
        isPointOffScreen(point) { return native.isPointOffScreen(point); },
        screenForRef(ref) { return native.screenForRef(ref); },
        screenCount() { return native.screenCount(); },
        eachScreen(callback) { return native.eachScreen(callback); },
      };
      addAliases(info, {
        eapp: "eachApp", wup: "windowUnderPoint", sup: "screenUnderPoint", rectoff: "isRectOffScreen",
        pntoff: "isPointOffScreen", screenr: "screenForRef", screenc: "screenCount", escreen: "eachScreen",
      }, true);

      const slate = Object.assign({
        log(...parts) { return native.log(parts.join(" ")); },
        config(name, value) { return native.config(name, value); },
        configAll(values) { return native.configAll(values); },
        bind(keystroke, target, repeat) { return native.bind(keystroke, target, repeat); },
        bindAll(bindings) { return native.bindAll(bindings); },
        operation(name, params) { return native.operation(name, params); },
        operationFromString(text) { return native.operationFromString(text); },
        doOperation(name, params) { return native.doOperation(name, params); },
        source(path) { return native.source(path); },
        layout(name, apps) { return native.layout(name, apps); },
        default(screens, target) { return native.defaultLayout(screens, target); },
        shell(command, wait, path) { return native.shell(command, wait, path); },
        on(event, callback) { return native.on(event, callback); },
        info: info,
      }, info);
      addAliases(slate, {
        cfg: "config", cfga: "configAll", bnd: "bind", bnda: "bindAll", op: "operation",
        opstr: "operationFromString", doop: "doOperation", src: "source", lay: "layout", def: "default",
        sh: "shell",
      }, true);

      // Slate ran configs in a web view, where the global object is `window`, and preloaded
      // underscore.js. This is a small, independent subset of underscore's API.
      function makeUnderscore() {
        const _ = {};
        const isArrayLike = (obj) => obj != null && typeof obj !== "function" && typeof obj.length === "number";
        const pairsOf = (obj) => {
          if (obj == null) return [];
          if (isArrayLike(obj)) return Array.prototype.map.call(obj, (value, index) => [value, index]);
          return Object.keys(obj).map((key) => [obj[key], key]);
        };
        const iteratee = (f) => {
          if (typeof f === "function") return f;
          if (f == null) return (value) => value;
          return (value) => (value == null ? undefined : value[f]);
        };
        const slice = (list, start, end) => Array.prototype.slice.call(list || [], start, end);

        _.each = _.forEach = (obj, f, context) => {
          for (const [value, key] of pairsOf(obj)) f.call(context, value, key, obj);
          return obj;
        };
        _.map = _.collect = (obj, f, context) => {
          const g = iteratee(f);
          return pairsOf(obj).map(([value, key]) => g.call(context, value, key, obj));
        };
        _.filter = _.select = (obj, f, context) => {
          const g = iteratee(f);
          return pairsOf(obj).filter(([value, key]) => g.call(context, value, key, obj)).map(([value]) => value);
        };
        _.reject = (obj, f, context) => {
          const g = iteratee(f);
          return _.filter(obj, (value, key, list) => !g.call(context, value, key, list));
        };
        _.find = _.detect = (obj, f, context) => {
          const g = iteratee(f);
          const hit = pairsOf(obj).find(([value, key]) => g.call(context, value, key, obj));
          return hit === undefined ? undefined : hit[0];
        };
        _.some = _.any = (obj, f, context) => {
          const g = iteratee(f);
          return pairsOf(obj).some(([value, key]) => g.call(context, value, key, obj));
        };
        _.every = _.all = (obj, f, context) => {
          const g = iteratee(f);
          return pairsOf(obj).every(([value, key]) => g.call(context, value, key, obj));
        };
        _.reduce = _.inject = _.foldl = function (obj, f, memo, context) {
          const pairs = pairsOf(obj);
          let start = 0;
          if (arguments.length < 3) {
            memo = pairs.length > 0 ? pairs[0][0] : undefined;
            start = 1;
          }
          for (let i = start; i < pairs.length; i++) memo = f.call(context, memo, pairs[i][0], pairs[i][1], obj);
          return memo;
        };
        _.values = (obj) => pairsOf(obj).map(([value]) => value);
        _.keys = (obj) => (obj == null ? [] : Object.keys(obj));
        _.size = (obj) => pairsOf(obj).length;
        _.contains = _.include = (obj, target) => _.values(obj).indexOf(target) >= 0;
        _.pluck = (obj, key) => _.map(obj, key);
        _.sortBy = (obj, f, context) => {
          const g = iteratee(f);
          return pairsOf(obj)
            .map(([value, key]) => ({ value: value, rank: g.call(context, value, key, obj) }))
            .sort((a, b) => (a.rank < b.rank ? -1 : a.rank > b.rank ? 1 : 0))
            .map((entry) => entry.value);
        };
        _.first = _.head = (list, n) => (n === undefined ? slice(list)[0] : slice(list, 0, n));
        _.last = (list, n) => {
          const items = slice(list);
          return n === undefined ? items[items.length - 1] : items.slice(Math.max(items.length - n, 0));
        };
        _.rest = _.tail = (list, n) => slice(list, n === undefined ? 1 : n);
        _.without = (list, ...values) => slice(list).filter((value) => values.indexOf(value) < 0);
        _.uniq = _.unique = (list) => slice(list).filter((value, index, items) => items.indexOf(value) === index);
        _.flatten = (list, shallow) =>
          slice(list).reduce((out, value) => out.concat(Array.isArray(value) && !shallow ? _.flatten(value) : value), []);
        _.range = function (start, stop, step) {
          if (arguments.length <= 1) {
            stop = start || 0;
            start = 0;
          }
          step = step || 1;
          const out = [];
          for (let x = start; step > 0 ? x < stop : x > stop; x += step) out.push(x);
          return out;
        };
        _.indexOf = (list, value) => slice(list).indexOf(value);
        _.times = (n, f, context) => _.range(n).map((i) => f.call(context, i));
        _.extend = (obj, ...sources) => Object.assign(obj, ...sources);
        _.defaults = (obj, ...sources) => {
          for (const source of sources) {
            for (const key in source) if (obj[key] === undefined) obj[key] = source[key];
          }
          return obj;
        };
        _.clone = (obj) =>
          obj === null || typeof obj !== "object" ? obj : Array.isArray(obj) ? obj.slice() : Object.assign({}, obj);
        _.has = (obj, key) => obj != null && Object.prototype.hasOwnProperty.call(obj, key);
        _.identity = (value) => value;
        _.bind = (f, context, ...args) => f.bind(context, ...args);
        _.isString = (x) => typeof x === "string" || x instanceof String;
        _.isNumber = (x) => typeof x === "number" || x instanceof Number;
        _.isBoolean = (x) => x === true || x === false || x instanceof Boolean;
        _.isFunction = (x) => typeof x === "function";
        _.isArray = Array.isArray;
        _.isObject = (x) => typeof x === "function" || (typeof x === "object" && x !== null);
        _.isUndefined = (x) => x === undefined;
        _.isNull = (x) => x === null;
        _.isEmpty = (x) => x == null || (isArrayLike(x) ? x.length === 0 : Object.keys(x).length === 0);
        return _;
      }

      global.slate = slate;
      global.S = slate;
      if (global.window === undefined) global.window = global;
      if (global._ === undefined) global._ = makeUnderscore();

      return { SlateOperation, SlateWindow, SlateApplication, SlateScreen };
    })
    """#
}
