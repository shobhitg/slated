// Node module customization hooks (module.register): resolve GJS-only imports to the mocks.
//
//   gi://Gtk?version=4.0  → the current mock world's Gtk namespace
//   cairo                 → its cairo module
//   resource:///org/gnome/Shell/Extensions/js/extensions/prefs.js → a stand-in ExtensionPreferences
//
// The generated modules forward to globalThis.__slatedWorld at access time, so a test can swap in a
// fresh world (min mode, new mode) while Node keeps the imported UI modules cached.

const forward = expression => `export default new Proxy({}, {
  get: (_t, key) => ${expression}[key],
  has: (_t, key) => key in ${expression},
});`;

export async function resolve(specifier, context, nextResolve) {
  // The preferences' imports of the engine get the stand-in (which imports the real engine itself).
  if (specifier.endsWith('/core/index.js') && !context.parentURL?.endsWith('/core-standin.mjs')) {
    return {url: new URL('./core-standin.mjs', import.meta.url).href, shortCircuit: true};
  }
  if (specifier.startsWith('gi://')) {
    return {url: `slated-mock:gi/${specifier.slice('gi://'.length).split('?')[0]}`, shortCircuit: true};
  }
  if (specifier === 'cairo') return {url: 'slated-mock:cairo', shortCircuit: true};
  if (specifier === 'resource:///org/gnome/Shell/Extensions/js/extensions/prefs.js') {
    return {url: 'slated-mock:prefs', shortCircuit: true};
  }
  return nextResolve(specifier, context);
}

export async function load(url, context, nextLoad) {
  if (!url.startsWith('slated-mock:')) return nextLoad(url, context);
  const what = url.slice('slated-mock:'.length);
  let source;
  if (what.startsWith('gi/')) {
    source = forward(`globalThis.__slatedWorld.namespaces[${JSON.stringify(what.slice(3))}]`);
  } else if (what === 'cairo') {
    source = forward('globalThis.__slatedWorld.cairo');
  } else {
    source = `
      const m = () => globalThis.__slatedWorld.prefsModule;
      export class ExtensionPreferences extends (globalThis.__slatedWorld.prefsModule.ExtensionPreferences) {}
      export const gettext = (...a) => m().gettext(...a);
      export const ngettext = (...a) => m().ngettext(...a);
      export const pgettext = (...a) => m().pgettext(...a);`;
  }
  return {format: 'module', source, shortCircuit: true};
}
