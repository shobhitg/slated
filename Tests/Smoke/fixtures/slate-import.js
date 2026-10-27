// A Slate config that imports only in part (the smoke tests import it).
slate.config("nudgePercentOf", "screenSize");
// Its value can change while Slated runs, so it must keep coming from the script.
slate.config("windowHintsCharacters", function () {
  return "ASDF" + slate.screenCount();
});
slate.bind("f16:ctrl,alt", slate.operation("push", { direction: "up" }));
// Needs the script: it moves the window itself.
slate.bind("f17:ctrl,alt", function (win) {
  win.move({ x: 0, y: 0 });
});
