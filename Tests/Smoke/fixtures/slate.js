// Smoke-test fixture: the constructs a typical Slate JavaScript config uses, in miniature.
var leftHalf = slate.operation("move", {
  "x": "screenOriginX", "y": "screenOriginY", "width": "screenSizeX/2", "height": "screenSizeY",
});
slate.bind("a:ctrl,shift,alt,cmd", (win) => { win.doOperation(leftHalf); });
slate.bind("w:ctrl,shift,alt,cmd", (win) => {
  win.doOperation(slate.operationFromString("push top bar-resize:screenSizeY/2"));
});
slate.bind("f:ctrl,shift,alt,cmd", (win) => {
  let rect = slate.screen().rect();
  win.doOperation(rect.width > rect.height ? "push" : "corner",
                  rect.width > rect.height ? {"direction": "left"} : {"direction": "top-left"});
});
slate.bind("tab:ctrl,shift,alt,cmd", (win) => {
  win.doOperation(slate.operationFromString("grid padding:4 0:6,6 1:6,6"));
});
