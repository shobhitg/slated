// An empty layout as the display default for up to six displays (the smoke tests check that
// config.json's own default wins over it).
slate.layout("file", {});
for (var count = 1; count <= 6; count++) slate.default(count, "file");
