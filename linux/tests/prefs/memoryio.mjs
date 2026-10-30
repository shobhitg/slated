// In-memory files for the settings model and the migration: config.json, settings.json, the
// config.v1.json backup, config-migration.json, settings-window.json and any Slate file, keyed by
// path in a plain object. `disk.__failWrites` makes every write throw.

export const HOME = '/home/me';
export const CONFIG = `${HOME}/.config/slated/config.json`;
export const SETTINGS = `${HOME}/.config/slated/settings.json`;
export const BACKUP = `${HOME}/.config/slated/config.v1.json`;
export const RECORD = `${HOME}/.local/state/slated/config-migration.json`;
export const WINDOW = `${HOME}/.local/state/slated/settings-window.json`;
export const SLATE_JS = `${HOME}/.slate.js`;
export const SLATE = `${HOME}/.slate`;

/**
 * The model's io (migration.ConfigFilesIO plus the window state) over `disk`. Every write is listed
 * in `writes` as [path, text], in order.
 */
export function memoryIO(disk, writes = []) {
  const read = path => (Object.prototype.hasOwnProperty.call(disk, path) ? disk[path] : null);
  const write = path => text => {
    if (disk.__failWrites) throw new Error('disk full');
    disk[path] = text;
    writes.push([path, text]);
  };
  return {
    home: HOME,
    readConfig: () => read(CONFIG),
    writeConfig: write(CONFIG),
    readSettings: () => read(SETTINGS),
    writeSettings: write(SETTINGS),
    backupConfig: text => {
      if (read(BACKUP) !== null) return false;
      write(BACKUP)(text);
      return true;
    },
    readRecord: () => read(RECORD),
    writeRecord: write(RECORD),
    readFile: read,
    readWindowState: () => read(WINDOW),
    writeWindowState: write(WINDOW),
  };
}

/** The paths written, in order, without repeats next to each other. */
export const writtenPaths = writes => writes.map(([path]) => path.slice(HOME.length + 1));
