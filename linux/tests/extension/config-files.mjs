// Writes a test configuration as Slated keeps it: config.json (keyboard, bindings, hotstrings,
// layouts, defaults) and settings.json (general, windows, clipboard, automation, island), both
// version 2. Tests describe it as one object, as the extension holds it in memory.

import {mkdirSync, writeFileSync} from 'node:fs';
import {join} from 'node:path';

const SETTINGS_SECTIONS = ['general', 'windows', 'clipboard', 'automation', 'island'];

export const configPathIn = (home) => join(home, '.config/slated/config.json');
export const settingsPathIn = (home) => join(home, '.config/slated/settings.json');

/** Writes `combined` split into the two files under `home`; returns their paths. */
export function writeConfigFiles(home, combined) {
  const config = {version: 2};
  const settings = {version: 2};
  for (const [key, value] of Object.entries(combined)) {
    if (SETTINGS_SECTIONS.includes(key)) settings[key] = value;
    else config[key] = value;
  }
  mkdirSync(join(home, '.config/slated'), {recursive: true});
  writeFileSync(configPathIn(home), JSON.stringify(config, null, 2));
  writeFileSync(settingsPathIn(home), JSON.stringify(settings, null, 2));
  return {config: configPathIn(home), settings: settingsPathIn(home)};
}
