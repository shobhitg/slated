// A window event handler, which Slated doesn't deliver (the smoke tests import it).
slate.bind("f16:ctrl,alt", slate.operation("push", { direction: "up" }));
slate.on("windowOpened", function (event, win) {
  win.doOperation("push left");
});
