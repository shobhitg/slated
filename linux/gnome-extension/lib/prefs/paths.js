// Where Slated for Linux keeps its files. Pure: callers pass the home folder and environment (in the
// preferences window that's GLib.get_home_dir() and GLib.getenv()).
//
// - config: $XDG_CONFIG_HOME/slated/config.json (default ~/.config/slated/config.json), the same
//   file the macOS app uses;
// - state:  $XDG_STATE_HOME/slated/ (default ~/.local/state/slated/) with status.json, written by
//   the extension, slated.log, the event log (JSON Lines, same events as on macOS), and
//   clipboard.json, the clipboard history (mode 0600; only the extension reads and writes it).
//
// As in the extension (lib/platform/paths.js) and on macOS, SLATED_HOME stands in for the home
// folder (then the XDG variables, which belong to the real home, don't apply) and SLATED_CONFIG for
// the config file, so tests can point everything at a throwaway home.

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
  return {
    home: base,
    configDir: configFile.replace(/\/[^/]*$/, ''),
    configFile,
    stateDir: `${stateHome}/slated`,
    statusFile: `${stateHome}/slated/status.json`,
    logFile: `${stateHome}/slated/slated.log`,
    clipboardFile: `${stateHome}/slated/clipboard.json`,
  };
}
