// Mistakes whose errors quote private text: an insert-text that types words without quotes, and a
// TypeError whose message includes a value (here a string standing in for a window title).
slate.bind("o:ctrl,cmd", slate.operationFromString("insert-text SECRETPHRASE my bank pin 4321"));
var title = "SECRETTITLE - a private subject line";
title();
