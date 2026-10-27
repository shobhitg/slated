// A Slate config that reacts to display changes (the smoke tests count its log lines).
slate.bind("left:ctrl,alt,cmd", slate.operation("push", { direction: "left", style: "bar-resize:screenSizeX/2" }));
slate.on("screenConfigurationChanged", function () {
  slate.log("screens changed");
});
