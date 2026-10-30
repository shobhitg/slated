// Where Slated keeps its files on Linux (XDG base directories):
//
//   ~/.config/slated/config.json          what your keys do (shared with the settings window and the Mac)
//   ~/.config/slated/settings.json        how Slated behaves (likewise)
//   ~/.config/slated/config.v1.json       the version 1 config.json the move to two files keeps
//   ~/.local/state/slated/slated.log      the event log (JSON Lines)
//   ~/.local/state/slated/status.json     live status for the preferences app
//   ~/.local/state/slated/snapshots.json  saved window snapshots
//   ~/.local/state/slated/hyper.json      what Slated changed in the keyboard options, to undo it
//   ~/.local/state/slated/clipboard.json  clipboard history (mode 0600), when clipboard.persist is on
//   ~/.local/state/slated/config-migration.json  what the move to two files imported, for the settings window
//   ~/.local/state/slated/settings-window.json   the settings window's own state (Get Started finished)
//
// `SLATED_HOME` stands in for the home directory and `SLATED_CONFIG` for config.json (settings.json
// and config.v1.json go beside it), like on macOS, so tests can point a running shell at a throwaway
// home. `SLATED_KEYD_CONF` moves keyd's config folder, as for linux/install.sh.

import GLib from 'gi://GLib';

import {abbreviateHome, expandHome} from './util.js';

export function homeDir() {
  return GLib.getenv('SLATED_HOME') || GLib.get_home_dir();
}

function configBase() {
  return GLib.getenv('SLATED_HOME') ? `${homeDir()}/.config` : GLib.get_user_config_dir();
}

function stateBase() {
  if (GLib.getenv('SLATED_HOME')) return `${homeDir()}/.local/state`;
  // GLib ≥ 2.72 knows XDG_STATE_HOME; every GNOME this extension supports ships a newer GLib.
  if (typeof GLib.get_user_state_dir === 'function') return GLib.get_user_state_dir();
  return GLib.getenv('XDG_STATE_HOME') || `${homeDir()}/.local/state`;
}

export function configPath() {
  return GLib.getenv('SLATED_CONFIG') || `${configBase()}/slated/config.json`;
}

function configDir() {
  return configPath().replace(/\/[^/]*$/, '');
}

export function settingsPath() {
  return `${configDir()}/settings.json`;
}

export function backupPath() {
  return `${configDir()}/config.v1.json`;
}

/** What the move to two files imported (the settings window tells you once from it). */
export function migrationRecordPath() {
  return `${stateDir()}/config-migration.json`;
}

/** The settings window's state: `{"setupFinished": true}` once Get Started is done. */
export function settingsWindowStatePath() {
  return `${stateDir()}/settings-window.json`;
}

export function stateDir() {
  return `${stateBase()}/slated`;
}

export function logPath() {
  return `${stateDir()}/slated.log`;
}

export function statusPath() {
  return `${stateDir()}/status.json`;
}

export function snapshotsPath() {
  return `${stateDir()}/snapshots.json`;
}

export function hyperStatePath() {
  return `${stateDir()}/hyper.json`;
}

/** Clipboard history, readable only by you (0600), in the Mac app's clipboard.json format. */
export function clipboardPath() {
  return `${stateDir()}/clipboard.json`;
}

/** The keyd config `linux/install.sh --hyper-keyd` writes; keyd's other configs are next to it. */
export function keydConfigPath() {
  return GLib.getenv('SLATED_KEYD_CONF') || '/etc/keyd/slated.conf';
}

export function espansoConfigDir() {
  return `${configBase()}/espanso`;
}

export function expand(path) {
  return expandHome(path, homeDir());
}

export function abbreviate(path) {
  return abbreviateHome(path, homeDir());
}
