// Fixture for the preferences importer tests (linux/tests/prefs/importer.test.mjs).
//
// Written in the style of a long-lived personal ~/.slate.js: operations bound to `let` variables,
// every binding an arrow function that calls win.doOperation, orientation checks through
// slate.screen().rect(), and Slate operation strings built inside the functions. It binds the same
// 21 Hyper (ctrl,shift,alt,cmd) shortcuts as Slated's built-in starter configuration, so importing
// it must produce exactly those bindings.

// Halves and quarters

let pushDown = slate.operation("push", {
  "direction" : "bottom",
  "style" : "bar-resize:screenSizeY/2",
});

let quarterTL = slate.operation("corner", {
  "direction" : "top-left",
  "width" : "screenSizeX/2",
  "height" : "screenSizeY/2",
});
let quarterTR = slate.operation("corner", {
  "direction" : "top-right",
  "width" : "screenSizeX/2",
  "height" : "screenSizeY/2",
});
let quarterBL = slate.operation("corner", {
  "direction" : "bottom-left",
  "width" : "screenSizeX/2",
  "height" : "screenSizeY/2",
});
let quarterBR = slate.operation("corner", {
  "direction" : "bottom-right",
  "width" : "screenSizeX/2",
  "height" : "screenSizeY/2",
});

let westHalf = slate.operation("move", {
  "x": "screenOriginX",
  "y": "screenOriginY",
  "width": "screenSizeX/2",
  "height": "screenSizeY",
});
let eastHalf = slate.operation("move", {
  "x": "screenOriginX+screenSizeX/2",
  "y": "screenOriginY",
  "width": "screenSizeX/2",
  "height": "screenSizeY",
});

// Centers and full screen

let middleSmall = slate.operation("move", {
  "x": "screenOriginX+screenSizeX/4",
  "y": "screenOriginY+screenSizeY/4",
  "width": "screenSizeX/2",
  "height": "screenSizeY/2",
});
let middleLarge = slate.operation("move", {
  "x" : "screenOriginX+screenSizeX/8",
  "y" : "screenOriginY+screenSizeY/8",
  "width" : "screenSizeX/1.3",
  "height" : "screenSizeY/1.3",
});
let everything = slate.operation("move", {
  "x": "screenOriginX",
  "y": "screenOriginY",
  "width": "screenSizeX",
  "height": "screenSizeY",
});

// Thirds: side by side on a wide screen, stacked on a tall one

  let wideThird0 = slate.operation("move", {
    "x": "screenOriginX",
    "y": "screenOriginY",
    "width": "screenSizeX/3",
    "height": "screenSizeY",
  });
  let wideThird1 = slate.operation("move", {
    "x": "screenOriginX+screenSizeX/3",
    "y": "screenOriginY",
    "width": "screenSizeX/3",
    "height": "screenSizeY",
  });
  let wideThird2 = slate.operation("move", {
    "x": "screenOriginX+screenSizeX*2/3",
    "y": "screenOriginY",
    "width": "screenSizeX/3",
    "height": "screenSizeY",
  });
  let wideTwoThirds0 = slate.operation("move", {
    "x": "screenOriginX",
    "y": "screenOriginY",
    "width": "screenSizeX*2/3",
    "height": "screenSizeY",
  });
  let wideTwoThirds1 = slate.operation("move", {
    "x": "screenOriginX+screenSizeX*1/3",
    "y": "screenOriginY",
    "width": "screenSizeX*2/3",
    "height": "screenSizeY",
  });

  let tallThird0 = slate.operation("move", {
    "x": "screenOriginX",
    "y": "screenOriginY",
    "width": "screenSizeX",
    "height": "screenSizeY/3",
  });
  let tallThird1 = slate.operation("move", {
    "x": "screenOriginX",
    "y": "screenOriginY+screenSizeY/3",
    "width": "screenSizeX",
    "height": "screenSizeY/3",
  });
  let tallThird2 = slate.operation("move", {
    "x": "screenOriginX",
    "y": "screenOriginY+screenSizeY*2/3",
    "width": "screenSizeX",
    "height": "screenSizeY/3",
  });
  let tallTwoThirds0 = slate.operation("move", {
    "x": "screenOriginX",
    "y": "screenOriginY",
    "width": "screenSizeX",
    "height": "screenSizeY*2/3",
  });
  let tallTwoThirds1 = slate.operation("move", {
    "x": "screenOriginX",
    "y": "screenOriginY+screenSizeY*1/3",
    "width": "screenSizeX",
    "height": "screenSizeY*2/3",
  });


// Bindings

slate.bind("':ctrl,shift,alt,cmd", (win) => {
    win.doOperation(middleSmall);
});

slate.bind("a:ctrl,shift,alt,cmd", (win) => {
    win.doOperation(westHalf);
});
slate.bind("d:ctrl,shift,alt,cmd", (win) => {
    win.doOperation(eastHalf);
});
slate.bind("q:ctrl,shift,alt,cmd", (win) => {
    win.doOperation(quarterTL);
});
slate.bind("e:ctrl,shift,alt,cmd", (win) => {
    win.doOperation(quarterTR);
});
slate.bind("z:ctrl,shift,alt,cmd", (win) => {
    win.doOperation(quarterBL);
});
slate.bind("c:ctrl,shift,alt,cmd", (win) => {
    win.doOperation(quarterBR);
});

slate.bind("f:ctrl,shift,alt,cmd", (win) => {
    let area = slate.screen().rect();
    let isWide = area.width > area.height;
    if (isWide) {
        win.doOperation(wideThird0);
    } else {
        win.doOperation(tallThird0);
    }

});
slate.bind("g:ctrl,shift,alt,cmd", (win) => {
    let area = slate.screen().rect();
    let isWide = area.width > area.height;
    if (isWide) {
        win.doOperation(wideThird1);
    } else {
        win.doOperation(tallThird1);
    }
});
slate.bind("h:ctrl,shift,alt,cmd", (win) => {
    let area = slate.screen().rect();
    if (area.width > area.height) {
        win.doOperation(wideThird2);
    } else {
        win.doOperation(tallThird2);
    }
});
slate.bind("v:ctrl,shift,alt,cmd", (win) => {
    let area = slate.screen().rect();
    let isWide = area.width > area.height;
    if (isWide) {
        win.doOperation(wideTwoThirds0);
    } else {
        win.doOperation(tallTwoThirds0);
    }
});
slate.bind("b:ctrl,shift,alt,cmd", (win) => {
    let area = slate.screen().rect();
    let isWide = area.width > area.height;
    if (isWide) {
        win.doOperation(wideTwoThirds1);
    } else {
        win.doOperation(tallTwoThirds1);
    }
});

slate.bind("return:ctrl,shift,alt,cmd", (win) => {
    win.doOperation(middleLarge);
});
slate.bind("s:ctrl,shift,alt,cmd", (win) => {
    win.doOperation(everything);
});
slate.bind("w:ctrl,shift,alt,cmd", (win) => {
    win.doOperation(slate.operationFromString("push top bar-resize:screenSizeY/2"));
});
slate.bind("x:ctrl,shift,alt,cmd", (win) => {
    win.doOperation(pushDown);
});


// Grid
slate.bind("tab:ctrl,shift,alt,cmd", (win) => {
    win.doOperation(slate.operationFromString("grid padding:4 0:6,6 1:6,6 2:6,6"));
});


// Throws
slate.bind("right:ctrl,shift,alt,cmd", (win) => {
    win.doOperation(slate.operationFromString("throw right resize"));
});
slate.bind("left:ctrl,shift,alt,cmd", (win) => {
    win.doOperation(slate.operationFromString("throw left  resize"));
});
slate.bind("up:ctrl,shift,alt,cmd", (win) => {
    win.doOperation(slate.operationFromString("throw up  resize"));
});
slate.bind("down:ctrl,shift,alt,cmd", (win) => {
    win.doOperation(slate.operationFromString("throw 1  resize"));
});
