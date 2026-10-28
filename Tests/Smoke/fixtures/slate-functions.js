// Smoke-test fixture: shortcuts that run functions. Slated lists the first by what it does (it tried
// it on pretend Macs); what the second does depends on the window, so it stays a function.
var wideThird = slate.operation("move", {
  "x": "screenOriginX", "y": "screenOriginY", "width": "screenSizeX/3", "height": "screenSizeY",
});
var tallThird = slate.operation("move", {
  "x": "screenOriginX", "y": "screenOriginY", "width": "screenSizeX", "height": "screenSizeY/3",
});
slate.bind("f:ctrl,shift,alt,cmd", (win) => {
  let rect = slate.screen().rect();
  win.doOperation(rect.width > rect.height ? wideThird : tallThird);
});
slate.bind("t:ctrl,shift,alt,cmd", (win) => {
  win.doOperation(win.title() === "Inbox" ? "push left" : "push right");
});
