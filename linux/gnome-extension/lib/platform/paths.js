// Where Slated keeps its files on Linux (XDG base directories):
//
//   ~/.config/slated/config.json          the configuration (shared with the preferences app)
//   ~/.local/state/slated/slated.log      the event log (JSON Lines)
//   ~/.local/state/slated/status.json     live status for the preferences app
//   ~/.local/state/slated/snapshots.json  saved window snapshots
//   ~/.local/state/slated/hyper.json      what Slated changed in the keyboard options, to undo it
//   ~/.local/state/slated/clipboard.json  clipboard history (mode 0600), when clipboard.persist is on
//
// `SLATED_HOME` stands in for the home directory and `SLATED_CONFIG` for the config file, like on
// macOS, so tests can point a running shell at a throwaway home.

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

export function espansoConfigDir() {
  return `${configBase()}/espanso`;
}

export function expand(path) {
  return expandHome(path, homeDir());
}

export function abbreviate(path) {
  return abbreviateHome(path, homeDir());
}
