// A layout applied when two displays are connected (the smoke tests import it).
slate.layout("coding", { "_before_": { "operations": [slate.operation("push", { direction: "up" })] } });
slate.default(2, "coding");
slate.bind("f16:ctrl,alt", slate.operation("layout", { name: "coding" }));
