// Lets Node import the extension's modules: `gi://…` and `resource:///…` imports resolve to stand-ins
// whose properties can be read (so module-level constants like `Meta.KeyBindingFlags.NONE` work) but
// which throw when called. Tests only exercise pure code; anything that really needs GNOME fails loudly.
//
// A test can instead provide working fakes: set `globalThis.__slatedGnomeFakes = {'gi://GLib': …}`
// before its first (dynamic) import of an extension module (see fake-gnome.mjs and runtime.test.mjs).
// Each test file runs in its own process, so fakes never leak between files.
//
// Used as `node --import ./gi-stubs.mjs --test …` (see run.sh).

import {registerHooks} from 'node:module';

const PREFIX = 'slated-stub:';

const NAMED_EXPORTS = {
  'resource:///org/gnome/shell/extensions/extension.js':
    'export const Extension = fake?.Extension ?? class Extension { constructor(metadata) { this.metadata = metadata; } };',
  'resource:///org/gnome/shell/misc/config.js':
    "export const PACKAGE_VERSION = fake?.PACKAGE_VERSION ?? '47.0';\nexport const PACKAGE_NAME = 'gnome-shell';",
  'resource:///org/gnome/shell/ui/status/keyboard.js': 'export const getInputSourceManager = fake?.getInputSourceManager ?? stub;',
  'resource:///org/gnome/shell/ui/main.js': [
    'wm',
    'layoutManager',
    'uiGroup',
    'overview',
    'panel',
    'sessionMode',
    'inputMethod',
    'messageTray',
    'extensionManager',
    'notify',
    'activateWindow',
    'pushModal',
    'popModal',
  ]
    .map((name) => `export const ${name} = fake?.${name} ?? stub;`)
    .join('\n'),
};

function stubSource(specifier) {
  return `
const label = ${JSON.stringify(specifier)};
const fake = globalThis.__slatedGnomeFakes?.[label] ?? null;
const handler = {
  get(target, property) {
    if (property === Symbol.toPrimitive) return () => '[GNOME stub ' + label + ']';
    if (property === 'then') return undefined; // not a thenable
    return new Proxy(function () {}, handler);
  },
  apply() {
    throw new Error('GNOME API called in a Node test (' + label + ')');
  },
  construct() {
    throw new Error('GNOME API called in a Node test (' + label + ')');
  },
};
const stub = new Proxy(function () {}, handler);
export default fake ?? stub;
${NAMED_EXPORTS[specifier] ?? ''}
`;
}

registerHooks({
  resolve(specifier, context, nextResolve) {
    if (specifier.startsWith('gi://') || specifier.startsWith('resource:///')) {
      return {url: PREFIX + specifier, shortCircuit: true};
    }
    return nextResolve(specifier, context);
  },
  load(url, context, nextLoad) {
    if (url.startsWith(PREFIX)) {
      return {format: 'module', shortCircuit: true, source: stubSource(url.slice(PREFIX.length))};
    }
    return nextLoad(url, context);
  },
});
