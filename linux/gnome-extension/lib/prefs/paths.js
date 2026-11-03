// Where Slated for Linux keeps its files. Pure: callers pass the home folder and environment (in the
// preferences window that's GLib.get_home_dir() and GLib.getenv()).
//
// - config: $XDG_CONFIG_HOME/slated/ (default ~/.config/slated/) with config.json (what your keys do)
//   and settings.json (how Slated behaves), the same files the macOS app uses, secrets.json
//   (sensitive hotstrings' text, mode 0600), and config.v1.json, the copy of a version 1 config.json
//   the move to two files keeps;
// - state:  $XDG_STATE_HOME/slated/ (default ~/.local/state/slated/) with status.json, written by
//   the extension, slated.log, the event log (JSON Lines, same events as on macOS), and
//   clipboard.json, the clipboard history (mode 0600; only the extension reads and writes it),
//   settings-window.json, the settings window's own state (whether Get Started was finished), and
//   config-migration.json, what the move to two files imported (for the one-time notice).
//
// As in the extension (lib/platform/paths.js) and on macOS, SLATED_HOME stands in for the home
// folder (then the XDG variables, which belong to the real home, don't apply) and SLATED_CONFIG for
// config.json (settings.json and config.v1.json go beside it), so tests can point everything at a
// throwaway home.
//
// keydConfig is the keyd configuration `linux/install.sh --hyper-keyd` installs (/etc/keyd/slated.conf,
// or SLATED_KEYD_CONF as for the installer). It's root's; the settings window only checks it's there.

/**
 * @param {string} home the home folder
 * @param {(name: string) => string|null} getenv environment lookup
 */
export function slatedPaths(home, getenv = () => null) {
  const absolute = value => (value && value.startsWith('/') ? value.replace(/\/+$/, '') : null);
  const override = absolute(getenv('SLATED_HOME'));
  const base = override ?? home.replace(/\/+$/, '');
  const configHome = (override ? null : absolute(getenv('XDG_CONFIG_HOME'))) ?? `${base}/.config`;
  const stateHome = (override ? null : absolute(getenv('XDG_STATE_HOME'))) ?? `${base}/.local/state`;
  const configFile = absolute(getenv('SLATED_CONFIG')) ?? `${configHome}/slated/config.json`;
  const configDir = configFile.replace(/\/[^/]*$/, '');
  return {
    home: base,
    configDir,
    configFile,
    settingsFile: `${configDir}/settings.json`,
    secretsFile: `${configDir}/secrets.json`,
    backupFile: `${configDir}/config.v1.json`,
    migrationFile: `${stateHome}/slated/config-migration.json`,
    stateDir: `${stateHome}/slated`,
    statusFile: `${stateHome}/slated/status.json`,
    logFile: `${stateHome}/slated/slated.log`,
    clipboardFile: `${stateHome}/slated/clipboard.json`,
    settingsWindowFile: `${stateHome}/slated/settings-window.json`,
    keydConfig: absolute(getenv('SLATED_KEYD_CONF')) ?? '/etc/keyd/slated.conf',
  };
}
