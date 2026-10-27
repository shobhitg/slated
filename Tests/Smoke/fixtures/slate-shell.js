// Uses a shell command's output while loading, as configs that check which Mac they're on do. The
// import can't run it, so this throws there (the smoke tests import it).
slate.bind("f16:ctrl,alt", slate.operation("push", { direction: "up" }));
var output = slate.shell("/usr/bin/true", true).trim();
slate.bind("f17:ctrl,alt", slate.operation("push", { direction: "down" }));
